module Pool
  class Retention
    def run
      SecretBinding.where(state:"available").where("expires_at <= ?",Time.current).find_each do |binding|
        binding.with_lock { SecretVault.new.revoke(binding);binding.update!(state:"expired") if binding.expires_at<=Time.current }
      end
      Artifact.where(state:"ready").where("retention_expires_at <= ?",Time.current).limit(100).each do |artifact|
        Tenant.find(artifact.tenant_id).with_lock do
          next if protected?(artifact)
          artifact.lock!
          path=BlobStore.new.path(artifact)
          # Metadata is marked expired before unlink: a failed unlink leaks space, never ready data.
          artifact.update!(state:"expired")
          File.unlink(path) if File.exist?(path)
        end
      end
      Operation.where.not(acknowledgement:nil).where("acknowledged_at < ?",7.days.ago).limit(100).each do |op|
        op.with_lock do
          chunks=OutputChunk.where(operation_id:op.id)
          if (last=chunks.maximum(:id))
            op.update!(output_first_seq:last+1)
            chunks.delete_all
          end
        end
      end
      PoolSession.where(state:%w[terminated failed]).where("updated_at < ?",90.days.ago).limit(100).each do |session|
        next if Operation.exists?(session_id:session.id,acknowledgement:nil)
        session.with_lock do
          events=PoolEvent.where(session_id:session.id)
          if (last=events.maximum(:id))
            session.update!(events_first_seq:last+1)
            events.delete_all
          end
        end
      end
      # Idempotency metadata is intentionally retained beyond the minimum30 days for now.
      # It is small and prevents reusing old operation keys; no payload/secrets are stored.
    end
    def protected?(artifact)
      return true if artifact.recovery_only
      pending=Operation.where(tenant_id:artifact.tenant_id,acknowledgement:nil)
      return true if pending.where("id = :operation OR input_artifact_id = :id OR request_artifact_id = :id OR candidate_checkpoint_id = :id OR result_artifact_id = :id",operation:artifact.operation_id,id:artifact.id).exists?
      PoolSession.where(tenant_id:artifact.tenant_id,last_accepted_checkpoint_id:artifact.id).where("state NOT IN ('terminated','failed') OR updated_at > ?",30.days.ago).exists?
    end
  end
end
