Sequel.migration do
  up {
    DB.create_table! :accounts do
      primary_key :id
      String   :email
      String   :password
      String   :is_admin
      String   :is_banned
      String   :ip
      String   :password_reset_token
      String   :editor_theme
      String   :email_confirmation_token
      Boolean  :email_confirmed
      String   :stripe_customer_id
      Boolean  :plan_ended, default: false
      Boolean  :is_deleted, default: false
      DateTime :created_at
      DateTime :updated_at
    end

    DB.add_column :sites, :account_id, :integer, index: true

    puts 'Migrating accounts...' unless ENV['RACK_ENV'] == 'test'

    DB[:sites].all.each do |site|
      site = DB[:sites].where(id: site[:id]).first
      next if site[:account_id]

      account_id = DB[:accounts].insert(
        email:                    site[:email],
        password:                 site[:password],
        is_admin:                 site[:is_admin],
        is_banned:                site[:is_banned],
        ip:                       site[:ip],
        password_reset_token:     site[:password_reset_token],
        editor_theme:             site[:editor_theme],
        email_confirmation_token: site[:email_confirmation_token],
        email_confirmed:          site[:email_confirmed],
        stripe_customer_id:       site[:stripe_customer_id],
        plan_ended:               site[:plan_ended],
        created_at:               site[:created_at],
        updated_at:               site[:updated_at]
      )

      account = DB[:accounts].where(id: account_id).first

      DB[:sites].where(id: site[:id]).update email: nil, password: nil, account_id: account[:id]

      # Accounts likely have duped emails, here we check for that, and add the passwords to
      # a separate table to check against. Gee wiz, I sure hope nobody is putting fake email
      # addresses in that match with other users' fake/real emails...

      site_duped_email_dataset = DB[:sites].exclude(id: site[:id]).where(email: site[:email])

      duped_sites = site_duped_email_dataset.all

      duped_sites.each do |duped_site|
        next if duped_site[:email].nil?
        DB[:sites].where(id: duped_site[:id]).update account_id: account[:id]
      end
    end

    %i{email is_admin is_banned ip password_reset_token editor_theme email_confirmation_token email_confirmed stripe_customer_id plan_ended}.each do |col|
      DB.drop_column :sites, col
    end

    puts 'done.' unless ENV['RACK_ENV'] == 'test'
  }

  down {
    raise 'THERE IS NO GOING BACK.' unless ENV['RACK_ENV'] == 'test'

    DB.drop_column :sites, :account_id
    DB.drop_table :accounts
    DB.drop_table :legacy_passwords

    # INCORRECT
    %i{email password is_admin is_banned ip password_reset_token editor_theme email_confirmation_token email_confirmed stripe_customer_id plan_ended}.each do |col|
      DB.add_column :sites, col, String, index: true
    end
  }
end