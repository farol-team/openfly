module Pool
  module ReservationLock
    def self.with(id)
      key=Digest::SHA256.hexdigest(id)[0,15].to_i(16)
      ApplicationRecord.connection_pool.with_connection do |connection|
        # Lock acquisition is volatile SQL. Rails query caching must never turn
        # an old true/false result into ownership of a different connection.
        connection.uncached do
          return false unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")
          begin
            yield
            true
          ensure
            connection.execute("SELECT pg_advisory_unlock(#{key})")
          end
        end
      end
    end
  end
end
