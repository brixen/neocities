require 'tilt'
require 'rss'
require 'nokogiri'
require 'pathname'

class Site < Sequel::Model
  include Sequel::ParanoidDelete

  VALID_MIME_TYPES = %w{
    text/plain
    text/html
    text/css
    application/javascript
    image/png
    image/jpeg
    image/gif
    image/svg+xml
    application/vnd.ms-fontobject
    application/x-font-ttf
    application/vnd.ms-opentype
    application/octet-stream
    text/csv
    text/tsv
    text/cache-manifest
    image/x-icon
    application/pdf
    application/pgp-keys
    application/pgp
    text/xml
    application/xml
    audio/midi
    text/cache-manifest
  }

  VALID_EXTENSIONS = %w{
    html htm txt text css js jpg jpeg png gif svg md markdown eot ttf woff woff2 json geojson csv tsv mf ico pdf asc key pgp xml mid midi manifest otf webapp
  }

  MINIMUM_PASSWORD_LENGTH = 5
  BAD_USERNAME_REGEX = /[^\w-]/i
  VALID_HOSTNAME = /^[a-z0-9][a-z0-9-]+?[a-z0-9]$/i # http://tools.ietf.org/html/rfc1123

  # FIXME smarter DIR_ROOT discovery
  DIR_ROOT             = './'
  TEMPLATE_ROOT        = File.join DIR_ROOT, 'views', 'templates'
  PUBLIC_ROOT          = File.join DIR_ROOT, 'public'
  SITE_FILES_ROOT      = File.join PUBLIC_ROOT, (ENV['RACK_ENV'] == 'test' ? 'sites_test' : 'sites')
  SCREENSHOTS_ROOT     = File.join(PUBLIC_ROOT, (ENV['RACK_ENV'] == 'test' ? 'site_screenshots_test' : 'site_screenshots'))
  THUMBNAILS_ROOT      = File.join(PUBLIC_ROOT, (ENV['RACK_ENV'] == 'test' ? 'site_thumbnails_test' : 'site_thumbnails'))
  SCREENSHOTS_URL_ROOT = ENV['RACK_ENV'] == 'test' ? '/site_screenshots_test' : '/site_screenshots'
  THUMBNAILS_URL_ROOT  = ENV['RACK_ENV'] == 'test' ? '/site_thumbnails_test' : '/site_thumbnails'
  DELETED_SITES_ROOT   = File.join PUBLIC_ROOT, 'deleted_sites'
  BANNED_SITES_ROOT    = File.join PUBLIC_ROOT, 'banned_sites'
  IMAGE_REGEX          = /jpg|jpeg|png|bmp|gif/
  LOSSLESS_IMAGE_REGEX = /png|bmp|gif/
  LOSSY_IMAGE_REGEX    = /jpg|jpeg/
  HTML_REGEX           = /.html$|.htm$/
  MAX_COMMENT_SIZE     = 420 # Used to be the limit for Facebook.. no comment (PUN NOT INTENDED).

  SCREENSHOT_RESOLUTIONS = ['540x405', '210x158', '100x100', '50x50']
  THUMBNAIL_RESOLUTIONS  = ['210x158']

  CLAMAV_THREAT_MATCHES = [
    /^VBS/,
    /^PUA\.Win32/,
    /^JS\.Popupper/,
    /Heuristic\.HTML\.Dropper/,
    /PHP\.Hide/
  ]

  SPAM_MATCH_REGEX = ENV['RACK_ENV'] == 'test' ? /pillz/ : /#{$config['spam_smart_filter'].join('|')}/i
  EMAIL_SANITY_REGEX = /.+@.+\..+/i
  EDITABLE_FILE_EXT = /html|htm|txt|js|css|md|manifest/i
  BANNED_TIME = 2592000 # 30 days in seconds
  TITLE_MAX = 100

  COMMENTING_ALLOWED_UPDATED_COUNT = 2

  SUGGESTIONS_LIMIT = 30
  SUGGESTIONS_VIEWS_MIN = 500
  CHILD_SITES_MAX = 100

  IP_CREATE_LIMIT = 1000
  TOTAL_IP_CREATE_LIMIT = 10000

  FROM_EMAIL = 'noreply@neocities.org'

  PLAN_FEATURES = {}

  PLAN_FEATURES[:supporter] = {
    name: 'Supporter',
    space: Filesize.from('5GB').to_i,
    bandwidth: Filesize.from('1TB').to_i,
    price: 5,
    unlimited_site_creation: true,
    custom_ssl_certificates: true,
    no_file_restrictions: true,
    custom_domains: true
  }

  PLAN_FEATURES[:free] = PLAN_FEATURES[:supporter].merge(
    name: 'Free',
    space: Filesize.from('50MB').to_i,
    bandwidth: Filesize.from('50GB').to_i,
    price: 0,
    unlimited_site_creation: false,
    custom_ssl_certificates: false,
    no_file_restrictions: false,
    custom_domains: false
  )

  def plan_feature(key)
    PLAN_FEATURES[plan_type.to_sym][key.to_sym]
  end

  def custom_domain_available?
    owner.plan_feature(:custom_domains) == true || !domain.nil?
  end

  LEGACY_SUPPORTER_PRICES = {
    plan_one: 1,
    plan_two: 2,
    plan_three: 3,
    plan_four: 4,
    plan_five: 5
  }

  BROWSE_PAGINATION_LENGTH = 300

  many_to_many :tags

  one_to_many :profile_comments
  one_to_many :profile_commentings, key: :actioning_site_id, class: :ProfileComment

  # Who is following this site
  one_to_many :follows

  # Who this site is following
  one_to_many :followings, key: :actioning_site_id, class: :Follow

  one_to_many :tips
  one_to_many :tippings, key: :actioning_site_id, class: :Tip

  one_to_many :blocks
  one_to_many :blockings, key: :actioning_site_id, class: :Block

  one_to_many :reports
  one_to_many :reportings, key: :reporting_site_id, class: :Report

  one_to_many :stats

  one_to_many :events

  one_to_many :site_changes

  many_to_one :parent, :key => :parent_site_id, :class => self
  one_to_many :children, :key => :parent_site_id, :class => self

  one_to_many :site_files

  def account_sites_dataset
    Site.where(Sequel.|({id: owner.id}, {parent_site_id: owner.id})).order(:parent_site_id.desc, :username)
  end

  def account_sites
    account_sites_dataset.all
  end

  def other_sites_dataset
    account_sites_dataset.exclude(id: self.id)
  end

  def other_sites
    account_sites_dataset.exclude(id: self.id).all
  end

  def account_sites_events_dataset
    ids = account_sites_dataset.select(:id).all.collect {|s| s.id}
    Event.where(id: ids)
  end

  def owner
    parent? ? self : parent
  end

  def owned_by?(site)
    !account_sites_dataset.select(:id).where(id: site.id).first.nil?
  end

  def add_profile_comment(opts)
    DB.transaction {
      profile_comment = super
      actioning_site = Site[id: opts[:actioning_site_id]]

      return if actioning_site.owner == owner

      send_email(
        col: :send_comment_emails,
        subject: "#{actioning_site.username.capitalize} commented on your site",
        body: render_template(
          'email/new_comment.erb',
          actioning_site: actioning_site,
          message: opts[:message],
          profile_comment: profile_comment
        )
      )
    }
  end

  class << self
    def valid_email_unsubscribe_token?(email, token)
      email_unsubscribe_token(email) == token
    end

    def email_unsubscribe_token(email)
      Digest::SHA2.hexdigest email+$config['email_unsubscribe_token']
    end

    def valid_login?(username_or_email, plaintext)
      site = get_with_identifier username_or_email

      return false if site.nil?
      return false if site.is_deleted
      site.valid_password? plaintext
    end

    def bcrypt_cost
      @bcrypt_cost
    end

    def bcrypt_cost=(cost)
      @bcrypt_cost = cost
    end

    def get_with_identifier(username_or_email)
      if username_or_email =~ /@/
        site = self.where(email: username_or_email).where(parent_site_id: nil).first
      else
        site = self[username: username_or_email]
      end
      return nil if site.nil? || site.is_banned || site.owner.is_banned
      site
    end

    def ip_create_limit?(ip)
      hashed_ip = hash_ip ip
      Site.where('created_at > ?', Date.today.to_time).where(ip: hashed_ip).count > IP_CREATE_LIMIT ||
      Site.where(ip: hashed_ip).count > TOTAL_IP_CREATE_LIMIT
    end

    def hash_ip(ip)
      SCrypt::Engine.hash_secret ip, $config['ip_hash_salt']
    end

    def banned_ip?(ip)
      return true if Site.where(is_banned: true).
        where(ip: hash_ip(ip)).
        where(['updated_at > ?', Time.now-BANNED_TIME]).
        first

      return true if BlockedIp[ip]

      false
    end

    def ssl_sites
      select(:id, :username, :domain, :ssl_key, :ssl_cert).
      exclude(domain: nil).
      exclude(ssl_key: nil).
      exclude(ssl_cert: nil).
      all
    end
  end

  def ip=(ip)
    super self.class.hash_ip(ip)
  end

  def is_following?(site)
    followings_dataset.select(:id).filter(site_id: site.id).first ? true : false
  end

  def toggle_follow(site)
    if is_following? site
      follow = followings_dataset.filter(site_id: site.id).first
      site.events_dataset.filter(follow_id: follow.id).delete
      follow.delete
      false
    else
      DB.transaction do
        follow = add_following site_id: site.id
        Event.create site_id: site.id, actioning_site_id: self.id, follow_id: follow.id
      end

      true
    end
  end

  def tip_amount
    return '0.00' if tips_dataset.count == 0
    '31.337'
  end

  def username=(val)
    super val.downcase
  end

  def unseen_notifications_dataset
    events_dataset.where(notification_seen: false).exclude(actioning_site_id: self.id)
  end

  def unseen_notifications_count
    @unseen_notifications_count ||= unseen_notifications_dataset.count
  end

  def valid_password?(plaintext)
    valid = BCrypt::Password.new(owner.values[:password]) == plaintext

    if !valid?
      return false if values[:password].nil?
      valid = BCrypt::Password.new(values[:password]) == plaintext
    end

    valid
  end

  def password=(plaintext)
    @password_length = plaintext.nil? ? 0 : plaintext.length
    @password_plaintext = plaintext
    super BCrypt::Password.create plaintext, cost: (self.class.bcrypt_cost || BCrypt::Engine::DEFAULT_COST)
  end

  def new_tags_string=(tags_string)
    @new_tags_string = tags_string
  end

  def save(validate={})
    DB.transaction do
      is_new = new?
      install_custom_domain if !domain.nil? && !domain.empty?
      result = super(validate)
      install_new_files if is_new
      result
    end
  end

  def install_custom_domain
    File.open(File.join(DIR_ROOT, 'domains', "#{username}.conf"), 'w') do |file|
      file.write render_template('domain.erb')
    end
  end

  def install_new_files
    FileUtils.mkdir_p files_path

    %w{index not_found}.each do |name|
      tmpfile = Tempfile.new "newinstall-#{name}"
      tmpfile.write render_template("#{name}.erb")
      tmpfile.close

      store_file "#{name}.html", tmpfile, new_install: true
      purge_cache "/#{name}.html"
      ScreenshotWorker.perform_async values[:username], "#{name}.html"
    end

    tmpfile = Tempfile.new 'style.css'
    tmpfile.close
    FileUtils.cp template_file_path('style.css'), tmpfile.path
    store_file 'style.css', tmpfile, new_install: true

    tmpfile = Tempfile.new 'cat.png'
    tmpfile.close
    FileUtils.cp template_file_path('cat.png'), tmpfile.path
    store_file 'cat.png', tmpfile, new_install: true
  end

  def get_file(path)
    File.read files_path(path)
  end

  def before_destroy
    DB.transaction {
      if !Dir.exist? DELETED_SITES_ROOT
        FileUtils.mkdir DELETED_SITES_ROOT
      end

      FileUtils.mv files_path, File.join(DELETED_SITES_ROOT, username)
      remove_all_tags
      #remove_all_events
      #Event.where(actioning_site_id: id).destroy
    }
  end

  def is_banned?
    is_banned
  end

  def ban!
    if username.nil? || username.empty?
      raise 'username is missing'
    end

    return if is_banned == true

    DB.transaction {
      self.is_banned = true
      self.updated_at = Time.now
      save(validate: false)

      if !Dir.exist? BANNED_SITES_ROOT
        FileUtils.mkdir BANNED_SITES_ROOT
      end

      FileUtils.mv files_path, File.join(BANNED_SITES_ROOT, username)
    }

    file_list.each do |path|
      purge_cache path
    end
  end

  def ban_all_sites_on_account!
    DB.transaction {
      account_sites.all {|site| site.ban! }
    }
  end

=begin
  def follows_dataset
    super.where(Sequel.~(site_id: blocking_site_ids))
    .where(Sequel.~(actioning_site_id: blocking_site_ids))
  end

  def followings_dataset
    super.where(Sequel.~(site_id: blocking_site_ids))
    .where(Sequel.~(actioning_site_id: blocking_site_ids))
  end

  def events_dataset
    super.where(Sequel.~(site_id: blocking_site_ids))
    .where(Sequel.~(actioning_site_id: blocking_site_ids))
  end
=end

  def commenting_allowed?
    return true if owner.commenting_allowed

    if owner.supporter?
      set commenting_allowed: true
      save_changes validate: false
      return true
    end

    if (account_sites_events_dataset.exclude(site_change_id: nil).count >= COMMENTING_ALLOWED_UPDATED_COUNT || (created_at < Date.new(2014, 12, 25).to_time && changed_count >= COMMENTING_ALLOWED_UPDATED_COUNT )) &&
       created_at < Time.now - 604800
      owner.set commenting_allowed: true
      owner.save_changes validate: false
      return true
    end

    false
  end

  def blocking_site_ids
    @blocking_site_ids ||= blockings_dataset.select(:site_id).all.collect {|s| s.site_id}
  end

  def block!(site)
    block = blockings_dataset.filter(site_id: site.id).first
    add_blocking site: site
  end

  def is_blocking?(site)
    @blockings ||= blockings
    !@blockings.select {|b| b.site_id == site.id}.empty?
  end

  def self.valid_username?(username)
    !username.empty? && username.match(/^[a-zA-Z0-9_\-]+$/i)
  end

  def okay_to_upload?(uploaded_file)
    return true if [:supporter].include?(plan_type.to_sym)
    self.class.valid_file_type?(uploaded_file)
  end

  def self.valid_file_type?(uploaded_file)
    mime_type = Magic.guess_file_mime_type uploaded_file[:tempfile].path
    extname = File.extname uploaded_file[:filename]

    # Possibly needed logic for .dotfiles
    #if extname == ''
    #  extname = uploaded_file[:filename]
    #end

    unless (Site::VALID_MIME_TYPES.include?(mime_type) || mime_type =~ /text/) &&
           Site::VALID_EXTENSIONS.include?(extname.sub(/^./, '').downcase)
      return false
    end

    # clamdscan doesn't work on travis for testing
    return true if ENV['TRAVIS'] == 'true'

    File.chmod 0666, uploaded_file[:tempfile].path
    line = Cocaine::CommandLine.new(
      "clamdscan", "-i --remove=no --no-summary --stdout :path",
      expected_outcodes: [0, 1]
    )

    output = line.run path: uploaded_file[:tempfile].path

    return true if output == ''

    threat = output.strip.match(/^.+: (.+) FOUND$/).captures.first

    CLAMAV_THREAT_MATCHES.each do |threat_match|
      return false if threat.match threat_match
    end

    true
  end

  def purge_cache(path)
    relative_path = path.gsub(base_files_path, '')
    payload = {site: username, path: relative_path}
    payload[:domain] = domain if !domain.empty?
    PurgeCacheWorker.perform_async payload
  end

  def store_file(path, uploaded, opts={})
    relative_path = scrubbed_path path
    path = files_path path
    pathname = Pathname(path)

    site_file = site_files_dataset.where(path: relative_path).first

    uploaded_sha1 = Digest::SHA1.file(uploaded.path).hexdigest

    if site_file && site_file.sha1_hash == uploaded_sha1
      return false
    end

    if pathname.extname.match EDITABLE_FILE_EXT
      open(uploaded.path, 'r:binary') {|f|
        matches = f.grep SPAM_MATCH_REGEX

        if !matches.empty?
=begin
          EmailWorker.perform_async({
            from: 'web@neocities.org',
            reply_to: email,
            to: 'spam@neocities.org',
            subject: "[Neocities SPAM]: #{username}",
            body: %{
              #{username}
              https://#{self.host}/#{relative_path}
            }
          })
=end
        end
      }
    end

    if relative_path == 'index.html' && opts[:new_install] != true
      begin
        new_title = Nokogiri::HTML(File.read(uploaded.path)).css('title').first.text
      rescue NoMethodError => e
      else
        if new_title.length < TITLE_MAX
          self.title = new_title
        end
      end

      self.site_changed = true
      self.site_updated_at = Time.now
      self.updated_at = Time.now

      save_changes(validate: false)
    end

    if pathname.extname.match HTML_REGEX
      # SPAM and phishing checking code goes here
    end

    dirname = pathname.dirname.to_s

    if !File.exists? dirname
      FileUtils.mkdir_p dirname
    end

    uploaded_size = uploaded.size

    FileUtils.cp uploaded.path, path
    File.chmod 0640, path

    site_file ||= SiteFile.new site_id: self.id, path: relative_path

    site_file.set_all(
      size: uploaded_size,
      sha1_hash: uploaded_sha1,
      updated_at: Time.now
    )
    site_file.save

    purge_cache path

    if pathname.extname.match HTML_REGEX
      ScreenshotWorker.perform_async values[:username], relative_path
    elsif pathname.extname.match IMAGE_REGEX
      ThumbnailWorker.perform_async values[:username], relative_path
    end

    SiteChange.record self, relative_path unless opts[:new_install]

    true
  end

  def is_directory?(path)
    File.directory? files_path(path)
  end

  def create_directory(path)
    relative_path = files_path path
    if Dir.exists?(relative_path) || File.exist?(relative_path)
      return 'Directory (or file) already exists.'
    end

    FileUtils.mkdir_p relative_path
    true
  end

  def increment_changed_count
    self.changed_count += 1
    save_changes(validate: false)
  end

  def files_zip
    zip_name = "neocities-#{username}"

    tmpfile = Tempfile.new 'neocities-site-zip'
    tmpfile.close

    Zip::Archive.open(tmpfile.path, Zip::CREATE) do |ar|
      ar.add_dir(zip_name)

      Dir.glob("#{base_files_path}/**/*").each do |path|
        relative_path = path.gsub(base_files_path+'/', '')

        if File.directory?(path)
          ar.add_dir(zip_name+'/'+relative_path)
        else
          ar.add_file(zip_name+'/'+relative_path, path) # add_file(<entry name>, <source path>)
        end
      end
    end

    tmpfile.path
  end

  def delete_file(path)
    begin
      FileUtils.rm files_path(path)
    rescue Errno::EISDIR
      site_files.each do |site_file|
        if site_file.path.match /^#{path}\//
          site_file.destroy
        end
      end
      FileUtils.remove_dir files_path(path), true
    rescue Errno::ENOENT
    end

    purge_cache path

    ext = File.extname(path).gsub(/^./, '')

    screenshots_delete(path) if ext.match HTML_REGEX
    thumbnails_delete(path) if ext.match IMAGE_REGEX

    path = path[1..path.length] if path[0] == '/'

    site_files_dataset.where(path: path).delete
    SiteChangeFile.filter(site_id: self.id, filename: path).delete

    true
  end

  def move_files_from(oldusername)
    FileUtils.mv base_files_path(oldusername), base_files_path
  end

  def install_new_html_file(path)
    File.write files_path(path), render_template('index.erb')
    purge_cache path
  end

  def file_exists?(path)
    File.exist? files_path(path)
  end

  def after_save
    save_tags
    super
  end

  def save_tags
    if @new_filtered_tags
      @new_filtered_tags.each do |new_tag_string|
        add_tag_name new_tag_string
      end
      @new_filtered_tags = []
      @new_tags_string = nil
    end
  end

  def add_tag_name(name)
    add_tag Tag[name: name] || Tag.create(name: name)
  end

  def before_create
    self.email_confirmation_token = SecureRandom.hex 3
    super
  end

  def email=(email)
    @original_email = values[:email] unless new?
    super
  end

  def can_email?(col=nil)
    return false unless owner.send_emails
    return false if col && !owner.send(col)
    true
  end

  def send_email(args={})
    %i{subject body}.each do |a|
      raise ArgumentError, "argument missing: #{a}" if args[a].nil?
    end

    if email && can_email?(args[:col])
      EmailWorker.perform_async({
        from: FROM_EMAIL,
        to: owner.email,
        subject: args[:subject],
        body: args[:body]
      })
    end
  end

  def parent?
    parent_site_id.nil?
  end

#  def after_destroy
#    FileUtils.rm_rf files_path
#    super
#  end

  def validate
    super

    if !self.class.valid_username?(values[:username])
      errors.add :username, 'Usernames can only contain letters, numbers, underscores and hyphens.'
    end

    if new? && !values[:username].nil? && !values[:username].empty?
      # TODO regex fails for usernames <= 2 chars, tempfix for now.
      if new? && values[:username].nil? || (values[:username].length > 2 && !values[:username].match(VALID_HOSTNAME))
        errors.add :username, 'A valid user/site name is required.'
      end

      if values[:username].length > 32
        errors.add :username, 'User/site name cannot exceed 32 characters.'
      end
    end

    # Check that email has been provided
    if parent? && values[:email].empty?
      errors.add :email, 'An email address is required.'
    end

    # Check for existing email if new or changing email.
    if new? || @original_email
      email_check = self.class.select(:id).filter(email: values[:email])
      email_check.exclude!(id: self.id) unless new?
      email_check = email_check.first

      if parent? && email_check && email_check.id != self.id
        errors.add :email, 'This email address already exists on Neocities, please use your existing account instead of creating a new one.'
      end
    end

    if parent? && (values[:email] =~ EMAIL_SANITY_REGEX).nil?
      errors.add :email, 'A valid email address is required.'
    end

    # Check for existing user
    user = self.class.select(:id, :username).filter(username: values[:username]).first

    if user
      if user.id != values[:id]
        errors.add :username, 'This username is already taken. Try using another one.'
      end
    end

    if parent? && (values[:password].nil? || (@password_length && @password_length < MINIMUM_PASSWORD_LENGTH))
      errors.add :password, "Password must be at least #{MINIMUM_PASSWORD_LENGTH} characters."
    end

    if !values[:domain].nil? && !values[:domain].empty?

      if values[:domain] =~ /neocities\.org/ || values[:domain] =~ /neocitiesops\.net/
        errors.add :domain, "Domain is already being used.. by Neocities."
      end

      if !(values[:domain] =~ /^[a-zA-Z0-9.-]+\.[a-zA-Z0-9]+$/i) || values[:domain].length > 90
        errors.add :domain, "Domain provided is not valid. Must take the form of domain.com"
      end

      site = Site[domain: values[:domain]]
      if !site.nil? && site.id != self.id
        errors.add :domain, "Domain provided is already being used by another site, please choose another."
      end

      if new? && !parent? && account_sites_dataset.count >= CHILD_SITES_MAX
        errors.add :child_site_id, "For spam prevention reasons, we've capped site creation to #{CHILD_SITES_MAX} sites. Please contact Neocities support to raise your site limit."
      end
    end

    if @new_tags_string
      new_tags = @new_tags_string.split ','
      new_tags.compact!
      @new_filtered_tags = []

      if ((new? ? 0 : tags_dataset.count) + new_tags.length > 5)
        errors.add :new_tags_string, 'Cannot have more than 5 tags for your site.'
      end

      new_tags.each do |tag|
        tag.strip!
        if tag.match(/[^a-zA-Z0-9 ]/)
          errors.add :new_tags_string, "Tag \"#{tag}\" can only contain letters (A-Z) and numbers (0-9)."
          break
        end

        if tag.length > Tag::NAME_LENGTH_MAX
          errors.add :new_tags_string, "Tag \"#{tag}\" cannot be longer than #{Tag::NAME_LENGTH_MAX} characters."
          break
        end

        if tag.match(/  /)
          errors.add :new_tags_string, "Tag \"#{tag}\" cannot have spaces."
          break
        end

        if tag.split(' ').length > Tag::NAME_WORDS_MAX
          errors.add :new_tags_string, "Tag \"#{tag}\" cannot be more than #{Tag::NAME_WORDS_MAX} word."
          break
        end

        next if tags.collect {|t| t.name}.include? tag

        @new_filtered_tags << tag
        @new_filtered_tags.uniq!
      end
    end
  end

  def render_template(name, locals={})
    Tilt.new(template_file_path(name), pretty: true).render self, locals
  end

  def template_file_path(name)
    File.join TEMPLATE_ROOT, name
  end

  def base_files_path(name=username)
    raise 'username missing' if name.nil? || name.empty?
    File.join SITE_FILES_ROOT, name
  end

  # https://practicingruby.com/articles/implementing-an-http-file-server?u=dc2ab0f9bb
  def scrubbed_path(path='')
    path ||= ''
    clean = []

    parts = path.split '/'

    parts.each do |part|
      next if part.empty? || part == '.'
      clean << part if part != '..'
    end

    clean.join '/'
  end

  def files_path(path='')
    File.join base_files_path, scrubbed_path(path)
  end

  def file_list(path='')
    list = Dir.glob(File.join(files_path(path), '*')).collect do |file_path|
      file = {
        path: file_path.gsub(base_files_path, ''),
        name: File.basename(file_path),
        ext: File.extname(file_path).gsub('.', ''),
        is_directory: File.directory?(file_path),
        is_root_index: file_path == "#{base_files_path}/index.html"
      }

      file[:is_html] = !(file[:ext].match HTML_REGEX).nil?
      file[:is_image] = !(file[:ext].match IMAGE_REGEX).nil?
      file[:is_editable] = !(file[:ext].match EDITABLE_FILE_EXT).nil?
      file
    end

    list.select {|f| f[:is_directory]}.sort_by {|f| f[:name]} +
    list.select {|f| f[:is_directory] == false}.sort_by{|f| f[:name].downcase}
  end

  def file_size_too_large?(size)
    return true if size + space_used > maximum_space
    false
  end

  def actual_space_used
    space = Dir.glob(File.join(files_path, '*')).collect {|p| File.size(p)}.inject {|sum,x| sum += x}
    space.nil? ? 0 : space
  end

  def total_space_used
    total = 0
    account_sites.each {|s| total += s.space_used}
    total
  end

  def remaining_space
    remaining = maximum_space - total_space_used
    remaining < 0 ? 0 : remaining
  end

  def maximum_space
    PLAN_FEATURES[(parent? ? self : parent).plan_type.to_sym][:space]
  end

  def space_percentage_used
    ((total_space_used.to_f / maximum_space) * 100).round(1)
  end

  def supporter?
    owner.plan_type != 'free'
  end

  def ended_supporter?
    owner.values[:plan_ended]
  end

  def plan_name
    PLAN_FEATURES[plan_type.to_sym][:name]
  end

  def unconverted_legacy_supporter?
    stripe_customer_id && !plan_ended && values[:plan_type].nil? && stripe_subscription_id.nil?
  end

  def legacy_supporter?
    return false if values[:plan_type].nil?
    !values[:plan_type].match(/plan_/).nil?
  end

  def plan_type
    return 'free' if owner.values[:plan_type].nil?
    return 'supporter' if owner.values[:plan_type].match /^plan_/
    return 'supporter' if owner.values[:plan_type] == 'special'
    owner.values[:plan_type]
  end

  def latest_events(current_page=1, limit=10)
    site_id = self.id
    Event.where{Sequel.|({site_id: site_id}, {actioning_site_id: site_id})}.
    order(:created_at.desc).
    paginate(current_page, limit)
  end

  def news_feed(current_page=1, limit=10)
    following_ids = self.followings_dataset.select(:site_id).all.collect {|f| f.site_id}
    search_ids = following_ids+[self.id]

    Event.where{Sequel.|({site_id: search_ids}, {actioning_site_id: search_ids})}.
    order(:created_at.desc).
    paginate(current_page, limit)
  end

  def host
    !domain.empty? ? domain : "#{username}.neocities.org"
  end

  def uri
    # Switch-over for when SSL defaulting is ready
    "http://#{host}"
  end

  def title
    if values[:title].nil? || values[:title].empty?
      !domain.nil? && !domain.empty? ? domain : "#{username}.neocities.org"
    else
      values[:title]
    end
  end

  def screenshots_delete(path)
    SCREENSHOT_RESOLUTIONS.each do |res|
      begin
        FileUtils.rm screenshot_path(path, res)
      rescue Errno::ENOENT
      end
    end
  end

  def thumbnails_delete(path)
    THUMBNAIL_RESOLUTIONS.each do |res|
      begin
        FileUtils.rm thumbnail_path(path, res)
      rescue Errno::ENOENT
      end
    end
  end

  def suggestions(limit=SUGGESTIONS_LIMIT, offset=0)
    suggestions_dataset = Site.exclude(id: id).exclude(is_banned: true).exclude(is_nsfw: true).order(:views.desc, :updated_at.desc)
    suggestions = suggestions_dataset.where(tags: tags).limit(limit, offset).all

    return suggestions if suggestions.length == limit

    suggestions += suggestions_dataset.where("views >= #{SUGGESTIONS_VIEWS_MIN}").limit(limit-suggestions.length).order(Sequel.lit('RANDOM()')).all
  end

  def screenshot_path(path, resolution)
    File.join(SCREENSHOTS_ROOT, values[:username], "#{path}.#{resolution}.jpg")
  end

  def screenshot_exists?(path, resolution)
    File.exist? File.join(SCREENSHOTS_ROOT, values[:username], "#{path}.#{resolution}.jpg")
  end

  def screenshot_url(path, resolution)
    "#{SCREENSHOTS_URL_ROOT}/#{values[:username]}/#{path}.#{resolution}.jpg"
  end

  def thumbnail_path(path, resolution)
    ext = File.extname(path).gsub('.', '').match(LOSSY_IMAGE_REGEX) ? 'jpg' : 'png'
    File.join THUMBNAILS_ROOT, values[:username], "#{path}.#{resolution}.#{ext}"
  end

  def thumbnail_exists?(path, resolution)
    File.exist? thumbnail_path(path, resolution)
  end

  def thumbnail_delete(path, resolution)
    File.rm thumbnail_path(path, resolution)
  end

  def thumbnail_url(path, resolution)
    ext = File.extname(path).gsub('.', '').match(LOSSY_IMAGE_REGEX) ? 'jpg' : 'png'
    "#{THUMBNAILS_URL_ROOT}/#{values[:username]}/#{path}.#{resolution}.#{ext}"
  end

  def ssl_installed?
    ssl_key && ssl_cert
  end

  def to_rss
    RSS::Maker.make("atom") do |maker|
      maker.channel.title   = title
      maker.channel.updated = updated_at
      maker.channel.author  = username
      maker.channel.id      = "#{username}.neocities.org"

      latest_events.each do |event|
        if event.site_change_id
          maker.items.new_item do |item|
            item.link = "https://#{host}"
            item.title = "#{title} has been updated"
            item.updated = event.site_change.created_at
          end
        end
      end
    end
  end
end
