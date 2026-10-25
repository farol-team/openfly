module Pool
  class Worker
    def initialize(provider:,runner_id:SecureRandom.hex(16))
      @provider,@runner_id=provider,runner_id
    end
    def run_once
      op=Scheduler.new.claim(@runner_id)
      return false unless op
      locked=ReservationLock.with(op.reservation_id) { execute(op) }
      unless locked
        Tenant.find(op.tenant_id).with_lock do
          op.reload
          if op.state=="preparing" && op.runner_id==@runner_id
            op.update!(state:"queued",runner_id:nil,runner_seen_at:nil,wait_reason:"reservation_busy")
          end
        end
      end
      true
    end
    def execute(op)
      epoch=op.lease_epoch
      session=PoolSession.find(op.session_id)
      reservation=Reservation.find(op.reservation_id)
      template=RuntimeTemplate.find(session.template_id)
      values={}
      create_attempted=false
      begin
        op.secret_binding_ids.each do |id|
          binding=SecretBinding.find_by!(id:id,tenant_id:op.tenant_id)
          values[binding.slot]=SecretVault.new.consume!(binding,op,epoch)
        end
        redactor=OutputRedactor.new(values.values)
        unless reservation.provider_id
          create_attempted=true
          identifier=@provider.create(reservation,template,session,guard:-> { guard!(op,epoch) })
          guarded(op,epoch) { reservation.update!(provider_id:identifier,state:"ready",observed_state:"running",observed_at:Time.current) }
        end
        # Record uncertain dispatch BEFORE contacting the provider. A crash here must not be retried.
        guarded(op,epoch) { op.update!(state:"running",execution_status:"unknown",started_at:Time.current) }
        result=@provider.execute(reservation,op,template,values,guard:-> { guard!(op,epoch) },on_output:->(chunk) { guarded(op,epoch) { raise Error.new("invalid_output") unless %w[stdout stderr].include?(chunk["stream"]); append_output(op,chunk["stream"],redactor.push(chunk["stream"],chunk["text"]),[]);op.redacted ||= redactor.redacted;op.save! } })
        guarded(op,epoch) { op.update!(state:"checkpointing",execution_status:"started") }
        checkpoint=result[:checkpoint] && BlobStore.new.internal!(op,"checkpoint",result[:checkpoint])
        structured=result[:result] && BlobStore.new.internal!(op,"result",JSON.generate(clean_result(result[:result],redactor.secrets)))
        guarded(op,epoch) do
          append_output(op,"stdout",redactor.push("stdout",result.fetch(:stdout,""),final:true),[])
          append_output(op,"stderr",redactor.push("stderr",result.fetch(:stderr,""),final:true),[])
          op.redacted ||= redactor.redacted
          op.update!(state:result.fetch(:exit_code)==0 ? "succeeded" : "failed",exit_code:result.fetch(:exit_code),candidate_checkpoint_id:checkpoint&.id,result_artifact_id:structured&.id,checkpoint_status:checkpoint ? "ready" : "unavailable",publication_eligibility:checkpoint ? "eligible" : "ineligible",finished_at:Time.current,capture_complete:true,truncated:op.truncated || result[:truncated]==true,error_code:result[:error_code])
          reservation.update!(observed_state:"running",observed_at:Time.current)
          session.update!(state:"parked",idle_since:Time.current,cleanup_status:"none")
          Lifecycle.event(session,"operation.#{op.state}",operation:op,details:{exit_code:op.exit_code,checkpoint_status:op.checkpoint_status})
        end
      rescue StandardError => error
        Tenant.find(op.tenant_id).with_lock do
          op.reload
          unless Presenter.terminal?(op)
            if op.execution_status=="not_started"
              Lifecycle.finish_unstarted!(op,"failed",error.is_a?(Error) ? error.code : "provider_prepare_failed")
            else
              Lifecycle.cancel!(op,error.is_a?(Error) ? error.code : "provider_outcome_unknown")
            end
          end
          # Even pre-dispatch provider creation may have succeeded despite a timeout.
          reservation.reload
          if !create_attempted && !reservation.provider_id && op.execution_status=="not_started"
            # This live stack proves provider creation was never dispatched. A lost
            # worker still follows conservative reconciliation, never this branch.
            reservation.update!(state:"released",released_at:Time.current,observed_state:"absent",observed_at:Time.current)
            session.reload.update!(state:session.state=="terminating" ? "terminated" : "parked",cleanup_status:"confirmed",idle_since:Time.current)
            Lifecycle.event(session,"reservation.released_without_dispatch",operation:op)
          else
            reservation.update!(state:"reconciling") unless reservation.released_at
            session.reload.update!(state:"recovering",cleanup_status:"pending") unless %w[terminating terminated].include?(session.reload.state)
          end
        end
      ensure
        values.clear
      end
    end
    def guarded(op,epoch)
      Tenant.find(op.tenant_id).with_lock do
        op.reload
        raise Error.new("writer_fenced") unless op.lease_epoch==epoch && op.runner_id==@runner_id && !Presenter.terminal?(op) && op.lease_expires_at>Time.current && op.deadline>Time.current
        op.update!(runner_seen_at:Time.current)
        yield
      end
    end
    def guard!(op,epoch)
      guarded(op,epoch) {}
      true
    end
    def append_output(op,stream,text,secrets)
      text=text.to_s.encode("UTF-8",invalid: :replace,undef: :replace)
      cleaned=text.dup
      secrets.reject(&:empty?).each { |secret| cleaned=cleaned.gsub(secret,"[REDACTED]") }
      cleaned=cleaned.gsub(/(Bearer\s+)[A-Za-z0-9._~+\/-]{16,}/i,'\1[REDACTED]').gsub(/((?:password|api_key|access_token)\s*[:=]\s*)[^\s]+/i,'\1[REDACTED]')
      op.redacted ||= cleaned!=text
      remaining=[1048576-op.output_bytes,0].max
      op.truncated ||= cleaned.bytesize>remaining
      cleaned=cleaned.byteslice(0,remaining).to_s.scrub
      # Characters, not raw byte cuts, keep UTF-8 valid; <= 16 KiB per chunk.
      cleaned.each_char.each_slice(4096) do |chars|
        chunk=chars.join
        OutputChunk.create!(tenant_id:op.tenant_id,operation_id:op.id,stream:stream,text:chunk,created_at:Time.current)
      end
      op.output_bytes+=cleaned.bytesize
    end
    def clean_result(value,secrets)
      case value
      when Hash then value.to_h { |key,item| [key, %w[password secret token api_key authorization].include?(key.to_s.downcase) ? "[REDACTED]" : clean_result(item,secrets)] }
      when Array then value.map { |item| clean_result(item,secrets) }
      when String then secrets.reject(&:empty?).reduce(value) { |text,secret| text.gsub(secret,"[REDACTED]") }
      else value
      end
    end
    # Explicit compatibility entrypoint for operator/tests; execution loop never calls it.
    def reconcile! = Reconciler.new(provider:@provider).run_once
  end
end
