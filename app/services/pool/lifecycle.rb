module Pool
  module Lifecycle
    def self.event(session,type,operation:nil,details:{})
      PoolEvent.create!(tenant_id:session.tenant_id,session_id:session.id,operation_id:operation&.id,event_type:type,details:details,created_at:Time.current)
    end
    def self.finish_unstarted!(op,state,code)
      op.update!(state:state,execution_status:"not_started",error_code:code,publication_eligibility:"ineligible",finished_at:Time.current,capture_complete:true)
      event(PoolSession.find(op.session_id),"operation.#{state}",operation:op,details:{code:code})
    end
    def self.cancel!(op,code="canceled")
      return if Presenter.terminal?(op)
      if op.state=="queued"
        finish_unstarted!(op,"canceled",code)
      else
        op.update!(state:"unknown",execution_status:"unknown",error_code:code,requires_reconciliation:true,publication_eligibility:"ineligible",lease_epoch:ApplicationRecord.uncached { ApplicationRecord.connection.select_value("SELECT nextval('operation_fencing_epochs')") },finished_at:Time.current)
        PoolSession.find(op.session_id).update!(state:"recovering",cleanup_status:"pending")
        Reservation.where(session_id:op.session_id,released_at:nil).update_all(state:"reconciling",updated_at:Time.current)
      end
    end
  end
end
