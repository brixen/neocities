require_relative './environment.rb'
require 'rack/test'

include Rack::Test::Methods

def app
  Sinatra::Application
end

describe 'migration to accounts' do
  before do
    DB.drop_tables!
    Sequel::Migrator.apply DB, './migrations', 45
  end

  after do
    DB.drop_tables!
    Sequel::Migrator.apply DB, './migrations'
  end

  it 'should work' do
    DB[:sites].insert username: 'derpie', password: 'derpiepass', email: 'derpie@example.com'
    Sequel::Migrator.apply DB, './migrations', 46

    site_cols = DB[:sites].columns
    site_cols.include?(:password).must_equal true
    site_cols.include?(:email).must_equal false

    site = Site.where(username: 'derpie').first
    site.username.must_equal 'derpie'

    site.account.email.must_equal 'derpie@example.com'
    site.account.password.must_equal 'derpiepass'
  end

  it 'should work for multiple sites with same email' do
    DB[:sites].insert username: 'derpie', password: 'derpiepass', email: 'derpie@example.com'
    DB[:sites].insert username: 'derpie2', password: 'derpiepass2', email: 'derpie@example.com'

    Sequel::Migrator.apply DB, './migrations', 46

    site = Site.where(username: 'derpie').first
    account_dataset = Account.where(email: 'derpie@example.com')
    account_dataset.count.must_equal 1

    account = account_dataset.first
    account.sites.length.must_equal 2

    account.sites_dataset.where(username: 'derpie').first.password.must_equal nil
    account.sites_dataset.where(username: 'derpie2').first.password.must_equal 'derpiepass2'
  end
end