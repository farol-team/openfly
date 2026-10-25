module Pool
  class Observer
    def initialize(provider:)
      @provider=provider
    end
    def self.due
      Reservation.where(released_at:nil,state:'ready').where('observed_at IS NULL OR observed_at < ?',60.seconds.ago).order(Arel.sql('observed_at ASC NULLS FIRST'))
    end
    def run(id)
      ReservationLock.with(id) do
        reservation=Reservation.find(id)
        next unless reservation.state=='ready' && !reservation.released_at
        state=@provider.observe(reservation)
        raise Error.new('invalid_observation') unless %w[running absent unknown].include?(state)
        reservation.update!(observed_state:state,observed_at:Time.current)
        # Absence is an observation, not proof that every recovery obligation has
        # been satisfied. Reconciliation still owns release of the reservation.
        if state=='absent'
          reservation.update!(state:'reconciling')
          PoolSession.find(reservation.session_id).update!(cleanup_status:'pending')
        end
      rescue StandardError
        reservation&.update!(observed_state:'unknown',observed_at:Time.current)
      end
    end
  end
end
