require "openssl"
module Pool
  module Auth
    def self.digest(value)
      OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("POOL_TOKEN_PEPPER"), value)
    end
    def self.issue!(tenant, scopes: %w[execution artifacts])
      token = SecureRandom.urlsafe_base64(48)
      ApiCredential.create!(tenant_id: tenant.id, digest: digest(token), scopes: scopes)
      token
    end
  end
end
