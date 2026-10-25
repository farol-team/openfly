Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  raise "SECRET_KEY_BASE required" unless ENV["SECRET_KEY_BASE"].to_s.size >= 64
  raise "POOL_TOKEN_PEPPER required" unless ENV["POOL_TOKEN_PEPPER"].to_s.size >= 64
end
