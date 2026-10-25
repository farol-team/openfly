module Pool
  class Reconciler
    def initialize(provider:)
      @provider=provider
    end
    def self.due
      Reservation.where(released_at:nil,state:%w[reconciling quarantined]).where("next_reconcile_at IS NULL OR next_reconcile_at <= ?",Time.current).order(Arel.sql("next_reconcile_at ASC NULLS FIRST, id ASC"))
    end
    def run_once(limit:8, ids:nil)
      scope=self.class.due
      scope=scope.where(id:ids) if ids
      scope.limit(limit).each do |reservation|
        ReservationLock.with(reservation.id) { reconcile_reservation(reservation) }
      end
    end
    def reconcile_reservation(reservation)
        reservation.reload
        return if reservation.released_at
        # Trusted provider checks deletion; a worker report alone cannot free resources.
        op=Operation.where(reservation_id:reservation.id).order(created_at: :desc).first
        if op && op.requires_reconciliation && @provider.respond_to?(:recover) && !Artifact.exists?(operation_id:op.id,kind:"recovery",state:"ready",recovery_only:true)
          bytes=@provider.recover(reservation)
          if bytes
            artifact=BlobStore.new.internal!(op,"recovery",bytes)
            artifact.update!(recovery_only:true,retention_expires_at:nil)
            Lifecycle.event(PoolSession.find(op.session_id),"recovery.saved",operation:op,details:{artifact_id:artifact.id})
          end
        end
        confirmed=@provider.delete_and_confirm(reservation)
        Tenant.find(reservation.tenant_id).with_lock do
          reservation.reload
          next if reservation.released_at
          session=PoolSession.find(reservation.session_id)
          if confirmed
            reservation.update!(state:"released",released_at:Time.current,observed_state:"absent",observed_at:Time.current,last_error_code:nil,next_reconcile_at:nil)
            session.update!(state:session.state=="terminating" || session.expires_at<=Time.current ? "terminated" : "parked",cleanup_status:"confirmed",idle_since:Time.current)
            Lifecycle.event(session,"guest.deleted")
          else
            defer(reservation,"cleanup_unconfirmed")
            session.update!(cleanup_status:"quarantined")
          end
        end
      rescue StandardError => error
        defer(reservation,error.is_a?(Error) ? error.code : "recovery_unavailable") unless reservation.reload.released_at
    end
    def defer(reservation,code)
      attempts=reservation.reconcile_attempts+1
      delay=[2**[attempts,8].min,300].min+rand(0..3)
      reservation.update!(state:"quarantined",reconcile_attempts:attempts,next_reconcile_at:delay.seconds.from_now,last_error_code:code,observed_state:"unknown",observed_at:Time.current)
      session=PoolSession.find(reservation.session_id)
      session.update!(cleanup_status:"quarantined")
      Lifecycle.event(session,"cleanup.deferred",details:{code:code,attempt:attempts,retry_in_seconds:delay})
    end
  end
end
