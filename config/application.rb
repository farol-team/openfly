require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "rails/test_unit/railtie"
Bundler.require(*Rails.groups)
module ExecutionPool
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true
    config.time_zone = "UTC"
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "development-only-#{'x' * 64}")
    config.active_record.schema_format = :sql
    config.active_record.dump_schema_after_migration = false
    config.filter_parameters += [:value, :authorization, :token, :secret, :argv, :text]
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = :warn
    config.hosts = ["127.0.0.1", "localhost", "www.example.com", ENV["POOL_HOST"]].compact
    config.action_dispatch.default_headers.merge!({"Cache-Control"=>"no-store", "X-Content-Type-Options"=>"nosniff", "X-Robots-Tag"=>"noindex"})
    config.autoload_lib(ignore: %w[tasks])
  end
end
