module Pool
  class Heartbeat
    def initialize(role,id:SecureRandom.uuid)
      @role,@id=role,id
    end
    def pulse
      now=Time.current
      ServiceHeartbeat.upsert({id:@id,role:@role,seen_at:now,created_at:now,updated_at:now})
    end
    def around
      pulse
      stopping=false
      thread=Thread.new do
        until stopping
          sleep 5
          break if stopping
          begin
            ApplicationRecord.connection_pool.with_connection { pulse }
          rescue StandardError
            # Failed writes must not extend readiness.
            sleep 1
          end
        end
      end
      yield
    ensure
      stopping=true
      thread&.kill;thread&.join
      ServiceHeartbeat.where(id:@id).delete_all rescue nil
    end
  end
end
