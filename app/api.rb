require 'base64'

get '/api' do
  @title = 'Developers API'
  erb :'api'
end

post '/api/upload' do
  require_api_credentials
  files = []
  params.each do |k,v|
    next unless v.is_a?(Hash) && v[:tempfile]
    path = k.to_s
    files << {filename: k || v[:filename], tempfile: v[:tempfile]}
  end

  api_error 400, 'missing_files', 'you must provide files to upload' if files.empty?

  uploaded_size = files.collect {|f| f[:tempfile].size}.inject{|sum,x| sum + x }

  if current_site.file_size_too_large? uploaded_size
    api_error 400, 'too_large', 'files are too large to fit in your space, try uploading smaller (or less) files'
  end

  files.each do |file|
    if !current_site.okay_to_upload?(file)
      api_error 400, 'invalid_file_type', "#{file[:filename]} is not a valid file type (or contains not allowed content) for this site, files have not been uploaded"
    end

    if File.directory? file[:filename]
      api_error 400, 'directory_exists', 'this name is being used by a directory, cannot continue'
    end
  end

  results = []
  files.each do |file|
    results << current_site.store_file(file[:filename], file[:tempfile])
  end

  current_site.increment_changed_count if results.include?(true)

  api_success 'your file(s) have been successfully uploaded'
end

post '/api/delete' do
  require_api_credentials

  api_error 400, 'missing_filenames', 'you must provide files to delete' if params[:filenames].nil? || params[:filenames].empty?

  paths = []
  params[:filenames].each do |path|
    unless path.is_a?(String)
      api_error 400, 'bad_filename', "#{path} is not a valid filename, canceled deleting"
    end

    if !current_site.file_exists?(path)
      api_error 400, 'missing_files', "#{path} was not found on your site, canceled deleting"
    end

    if path == 'index.html'
      api_error 400, 'cannot_delete_index', 'you cannot delete your index.html file, canceled deleting'
    end

    paths << path
  end

  paths.each do |path|
    current_site.delete_file(path)
  end

  api_success 'file(s) have been deleted'
end

get '/api/info' do
  if params[:sitename]
    site = Site[username: params[:sitename]]

    api_error 400, 'site_not_found', "could not find site #{params[:sitename]}" if site.nil? || site.is_banned
    api_success api_info_for(site)
  else
    init_api_credentials
    api_success api_info_for(current_site)
  end
end

def api_info_for(site)
  {
    info: {
      sitename: site.username,
      views: site.views,
      hits: site.hits,
      created_at: site.created_at.rfc2822,
      last_updated: site.site_updated_at ? site.site_updated_at.rfc2822 : nil,
      domain: site.domain,
      tags: site.tags.collect {|t| t.name}
    }
  }
end

# Catch-all for missing api calls

get '/api/:name' do
  api_not_found
end

post '/api/:name' do
  api_not_found
end

def require_api_credentials
  if !request.env['HTTP_AUTHORIZATION'].nil?
    init_api_credentials
  else
    api_error_invalid_auth
  end
end

def init_api_credentials
  auth = request.env['HTTP_AUTHORIZATION']

  begin
    user, pass = Base64.decode64(auth.match(/Basic (.+)/)[1]).split(':')
  rescue
    api_error_invalid_auth
  end

  if Site.valid_login? user, pass
    site = Site[username: user]

    if site.nil? || site.is_banned
      api_error_invalid_auth
    end

    session[:id] = site.id
  else
    api_error_invalid_auth
  end
end

def api_success(message_or_obj)
  output = {result: 'success'}

  if message_or_obj.is_a?(String)
    output[:message] = message_or_obj
  else
    output.merge! message_or_obj
  end

  api_response(200, output)
end

def api_response(status, output)
  halt status, JSON.pretty_generate(output)+"\n"
end

def api_error(status, error_type, message)
  api_response(status, result: 'error', error_type: error_type, message: message)
end

def api_error_invalid_auth
  api_error 403, 'invalid_auth', 'invalid credentials - please check your username and password'
end

def api_not_found
  api_error 404, 'not_found', 'the requested api call does not exist'
end