module Pool
  module Presenter
    def self.call(record)
      case record
      when Artifact
        record.attributes.slice(*%w[id state kind media_type size_bytes sha256 operation_id retention_expires_at recovery_only])
      when PoolSession
        record.attributes.slice(*%w[id state generation revision cleanup_status expires_at idle_timeout_seconds last_accepted_checkpoint_id]).tap do |data|
          reservation=Reservation.where(session_id:record.id).order(created_at: :desc).first
          fresh=reservation&.observed_at && reservation.observed_at>90.seconds.ago
          data["vm_state"]=fresh ? reservation.observed_state : "unknown"
          data["vm_observed_at"]=reservation&.observed_at
          data["vm_present"]=fresh ? reservation.observed_state=="running" : nil
        end
      when SecretBinding
        record.attributes.slice(*%w[id session_id operation_key slot expires_at state])
      when Operation
        record.attributes.slice(*%w[id session_id state execution_status exit_code generation expected_session_revision input_workspace_revision input_artifact_sha256 publication_eligibility candidate_checkpoint_id result_artifact_id checkpoint_status acknowledgement lease_expires_at deadline error_code requires_reconciliation wait_reason]).tap { |x| x["lease_expires_at"]=nil if terminal?(record) }
      end
    end
    def self.terminal?(operation) = %w[succeeded failed canceled timed_out interrupted unknown].include?(operation.state)
  end
end
