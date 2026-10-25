module Pool
  class Scheduler
    def claim(runner_id)
      # A short global scheduling transaction gives fair tenant order and no node oversubscription.
      # Remote/provider I/O never runs inside this transaction.
      ApplicationRecord.transaction do
        return nil unless ApplicationRecord.uncached { ApplicationRecord.connection.select_value("SELECT pg_try_advisory_xact_lock(428201)") }
        Tenant.where(id:Operation.where(state:"queued").select(:tenant_id)).order(Arel.sql("last_scheduled_at ASC NULLS FIRST, id ASC")).each do |tenant|
          tenant.lock!
          Operation.where(tenant_id:tenant.id,state:"queued").order(:created_at,:id).each do |op|
          session=PoolSession.find(op.session_id)
          if op.lease_expires_at<=Time.current || op.queue_deadline<=Time.current || session.expires_at<=Time.current
            Lifecycle.finish_unstarted!(op,"timed_out","queue_or_lease_expired")
            next
          end
          reservation=Reservation.find_by(session_id:session.id,released_at:nil)
          if reservation
            unless reservation.state=="ready" && Node.where(id:reservation.node_id,state:"ready").where("checked_at > ?",90.seconds.ago).exists?
              op.update!(wait_reason:"runtime_unavailable")
              next
            end
          else
            profile=RuntimeTemplate.find(session.template_id).resource_profiles.fetch(session.resource_profile)
            used=Reservation.where(tenant_id:tenant.id,released_at:nil)
            if used.sum(:vcpus)+profile.fetch("vcpus")>tenant.max_vcpus || used.sum(:memory_mib)+profile.fetch("memory_mib")>tenant.max_memory_mib
              op.update!(wait_reason:"tenant_capacity")
              next
            end
            node=Node.where(state:"ready").where("checked_at > ?",90.seconds.ago).order(:id).find do |candidate|
              next false unless compatible?(candidate,session,profile)
              r=Reservation.where(node_id:candidate.id,released_at:nil)
              r.sum(:vcpus)+profile.fetch("vcpus")<=candidate.vcpus && r.sum(:memory_mib)+profile.fetch("memory_mib")<=candidate.memory_mib && r.sum(:disk_mib)+profile.fetch("disk_mib")<=candidate.disk_mib
            end
            unless node
              op.update!(wait_reason:"pool_capacity")
              idle=PoolSession.where(state:"parked").where.not(id:session.id).order(:idle_since).first
              if idle
                Reservation.where(session_id:idle.id,released_at:nil,state:"ready").update_all(state:"reconciling",updated_at:Time.current)
                idle.update!(cleanup_status:"pending")
              end
              next
            end
            reservation=Reservation.create!(tenant_id:tenant.id,session_id:session.id,node_id:node.id,creation_key:SecureRandom.hex(24),vcpus:profile.fetch("vcpus"),memory_mib:profile.fetch("memory_mib"),disk_mib:profile.fetch("disk_mib"))
            session.update!(generation:session.generation+1,state:"allocating")
          end
          op.update!(wait_reason:nil,state:"preparing",generation:session.generation,reservation_id:reservation.id,lease_epoch:ApplicationRecord.uncached { ApplicationRecord.connection.select_value("SELECT nextval('operation_fencing_epochs')") },runner_id:runner_id,runner_seen_at:Time.current)
          session.update!(state:"busy",idle_since:nil)
          tenant.update!(last_scheduled_at:Time.current)
          Lifecycle.event(session,"operation.claimed",operation:op,details:{generation:op.generation})
          return op
          end
        end
        nil
      end
    end
    def compatible?(node,session,profile)
      return true if Rails.env.test? && node.provider=="fake"
      return false unless node.config.fetch("template_ids",[]).include?(session.template_id)
      return false unless node.config.fetch("network_profiles",[]).include?(session.network_profile)
      return ENV["POOL_ALLOW_DOCKER_TEST"]=="1" && !Rails.env.production? if node.provider=="docker_test"
      node.provider=="cubesandbox" && node.config["admission_passed"]==true && node.config["template_digest"]==RuntimeTemplate.find(session.template_id).image_digest && node.config["resources"]==profile
    end
    def expire!
      Tenant.find_each do |tenant|
        tenant.with_lock do
          Operation.where(tenant_id:tenant.id,state:%w[queued preparing running checkpointing]).each do |op|
            expired=op.lease_expires_at<=Time.current || op.deadline<=Time.current || (op.runner_seen_at && op.runner_seen_at<45.seconds.ago)
            Lifecycle.cancel!(op,"lease_or_deadline_expired") if expired
          end
          PoolSession.where(tenant_id:tenant.id).where.not(state:%w[terminated failed]).each do |session|
            timed_out=session.expires_at<=Time.current
            idle=session.state=="parked" && session.idle_since && session.idle_since<=session.idle_timeout_seconds.seconds.ago
            next unless timed_out || idle
            Operation.where(session_id:session.id).each { |op| Lifecycle.cancel!(op,"session_expired") } if timed_out
            r=Reservation.where(session_id:session.id,released_at:nil)
            r.update_all(state:"reconciling",updated_at:Time.current)
            session.update!(state:timed_out ? (r.exists? ? "terminating" : "terminated") : "parked",cleanup_status:r.exists? ? "pending" : "confirmed")
          end
        end
      end
    end
  end
end
