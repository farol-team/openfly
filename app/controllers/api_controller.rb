class ApiController < ActionController::API
  before_action :authenticate!
  rescue_from Pool::Error do |error|
    response.set_header("Retry-After","15") if error.status==429
    render json:{error:{code:error.code,message:error.message,request_id:request.request_id}},status:error.status
  end
  rescue_from ActiveRecord::RecordNotFound do
    render json:{error:{code:"not_found",message:"Resource unavailable",request_id:request.request_id}},status:404
  end
  rescue_from ActiveRecord::RecordNotUnique do
    render json:{error:{code:"state_conflict",message:"Resource already exists or is busy",request_id:request.request_id}},status:409
  end
  rescue_from JSON::ParserError, ActionDispatch::Http::Parameters::ParseError do
    render json:{error:{code:"invalid_json",message:"Invalid JSON",request_id:request.request_id}},status:400
  end
  def operator_status
    require_scope!("operator")
    render json:Pool::Observability.new.call
  end
  def templates
    require_scope!("execution")
    render json:{templates:RuntimeTemplate.where(id:@tenant.template_ids,enabled:true).map { |t| {id:t.id,image_digest:t.image_digest,resource_profiles:t.resource_profiles.keys,network_profiles:t.network_profiles.keys,secret_slots:t.secret_slots.keys} }}
  end
  def quota
    require_scope!("execution")
    r=Reservation.where(tenant_id:@tenant.id,released_at:nil)
    render json:{max_reserved_vcpus:@tenant.max_vcpus,reserved_vcpus:r.sum(:vcpus),max_reserved_memory_mib:@tenant.max_memory_mib,reserved_memory_mib:r.sum(:memory_mib),queued_operations:Operation.where(tenant_id:@tenant.id,state:"queued").count,parked_sessions:PoolSession.where(tenant_id:@tenant.id,state:"parked").count}
  end
  def create_artifact
    require_scope!("artifacts")
    data=body!("CreateArtifact")
    mutate(data,201) { Artifact.create!(data.merge(tenant_id:@tenant.id,retention_expires_at:7.days.from_now)) }
  end
  def artifact
    require_scope!("artifacts");render json:Pool::Presenter.call(owned(Artifact))
  end
  def upload
    require_scope!("artifacts")
    artifact=owned(Artifact)
    raise Pool::Error.new("immutable_artifact",409) unless %w[workspace_input operation_request].include?(artifact.kind)
    Pool::BlobStore.new.upload!(artifact,request.body)
    head :no_content
  end
  def download
    require_scope!("artifacts");artifact=owned(Artifact)
    raise Pool::Error.new("artifact_expired",410) if artifact.state=="expired"
    raise Pool::Error.new("artifact_not_ready") unless artifact.state=="ready"
    send_file Pool::BlobStore.new.path(artifact),type:artifact.media_type,disposition:"attachment",filename:artifact.id
  end
  def create_session
    require_scope!("execution");data=body!("CreateSession")
    mutate(data,202) do
      template=RuntimeTemplate.find_by!(id:data["template_id"],enabled:true)
      raise Pool::Error.new("template_forbidden",403) unless @tenant.template_ids.include?(template.id)
      raise Pool::Error.new("profile_forbidden",403) unless template.resource_profiles.key?(data["resource_profile"]) && template.network_profiles.key?(data["network_profile"])
      raise Pool::Error.new("tenant_quota",429) if PoolSession.where(tenant_id:@tenant.id).where.not(state:%w[terminated failed]).count>=@tenant.max_queued
      ttl=data.delete("ttl_seconds") || 3600
      session=PoolSession.create!(data.merge(tenant_id:@tenant.id,expires_at:ttl.seconds.from_now,idle_timeout_seconds:data.fetch("idle_timeout_seconds",600)))
      Pool::Lifecycle.event(session,"session.created")
      session
    end
  end
  def show_session
    require_scope!("execution");render json:Pool::Presenter.call(owned(PoolSession))
  end
  def terminate
    require_scope!("execution");session=owned(PoolSession)
    @tenant.with_lock do
      unless session.reload.state=="terminated"
        Operation.where(session_id:session.id).each { |op| Pool::Lifecycle.cancel!(op,"session_closed") }
        reservations=Reservation.where(session_id:session.id,released_at:nil)
        reservations.update_all(state:"reconciling",updated_at:Time.current)
        session.update!(state:reservations.exists? ? "terminating" : "terminated",cleanup_status:reservations.exists? ? "pending" : "confirmed")
        Pool::Lifecycle.event(session,"session.close_requested")
      end
    end
    render json:Pool::Presenter.call(session),status:session.state=="terminated" ? 200 : 202
  end
  def create_secret
    require_scope!("execution");data=body!("CreateSecretBinding")
    mutate(data,201) do
      session=owned(PoolSession,data.fetch("session_id"));ensure_open!(session)
      template=RuntimeTemplate.find(session.template_id)
      raise Pool::Error.new("secret_slot_forbidden",403) unless template.secret_slots.key?(data["slot"])
      binding=SecretBinding.create!(data.except("value","ttl_seconds").merge(tenant_id:@tenant.id,expires_at:data.fetch("ttl_seconds").seconds.from_now))
      Pool::SecretVault.new.put(binding,data.fetch("value"))
      binding
    end
  end
  def revoke_secret
    require_scope!("execution");binding=owned(SecretBinding)
    binding.with_lock { Pool::SecretVault.new.revoke(binding);binding.update!(state:"revoked") }
    render json:Pool::Presenter.call(binding)
  end
  def create_operation
    require_scope!("execution");data=body!("CreateOperation")
    mutate(data,202) do
      session=owned(PoolSession);ensure_open!(session)
      raise Pool::Error.new("revision_conflict") unless data["expected_session_revision"]==session.revision
      raise Pool::Error.new("workspace_busy") if WorkspaceLock.exists?(tenant_id:@tenant.id,workspace_key:session.workspace_key)
      raise Pool::Error.new("operation_exists") if Operation.exists?(session_id:session.id,operation_key:data["operation_key"])
      raise Pool::Error.new("acknowledgement_required") if Operation.exists?(session_id:session.id,acknowledgement:nil)
      raise Pool::Error.new("tenant_quota",429) if Operation.where(tenant_id:@tenant.id,state:"queued").count>=@tenant.max_queued
      input=owned(Artifact,data["input_artifact_id"])
      raise Pool::Error.new("input_not_ready") unless input.state=="ready" && %w[workspace_input checkpoint].include?(input.kind) && !input.recovery_only
      if data["request_artifact_id"]
        artifact=owned(Artifact,data["request_artifact_id"])
        raise Pool::Error.new("request_not_ready") unless artifact.state=="ready" && artifact.kind=="operation_request"
      end
      Array(data["secret_binding_ids"]).each do |id|
        secret=owned(SecretBinding,id)
        raise Pool::Error.new("secret_unavailable") unless secret.session_id==session.id && secret.operation_key==data["operation_key"] && secret.state=="available"
      end
      op=Operation.create!(data.merge(request_id:request.request_id,tenant_id:@tenant.id,session_id:session.id,input_artifact_sha256:input.sha256,generation:session.generation,lease_expires_at:90.seconds.from_now,queue_deadline:[300.seconds.from_now,session.expires_at].min,deadline:[(300+data["timeout_seconds"]).seconds.from_now,session.expires_at].min))
      WorkspaceLock.create!(tenant_id:@tenant.id,workspace_key:session.workspace_key,operation_id:op.id)
      Pool::Lifecycle.event(session,"operation.queued",operation:op)
      op
    end
  end
  def operation
    require_scope!("execution");render json:Pool::Presenter.call(owned(Operation))
  end
  def heartbeat
    require_scope!("execution")
    mutate({},200,serializer:->(op) {{lease_expires_at:op.lease_expires_at}}) do
      op=owned(Operation)
      raise Pool::Error.new("lease_inactive") if Pool::Presenter.terminal?(op) || op.lease_expires_at<=Time.current || op.deadline<=Time.current
      op.update!(lease_expires_at:[90.seconds.from_now,op.deadline].min)
      op
    end
  end
  def cancel
    require_scope!("execution")
    mutate({},202) do
      op=owned(Operation);Pool::Lifecycle.cancel!(op);op
    end
  end
  def acknowledge
    require_scope!("execution");data=body!("AcknowledgementRequest")
    mutate(data,200,serializer:->(op) {{operation_id:op.id,decision:op.acknowledgement,session_revision:op.acknowledged_revision}}) do
      op=owned(Operation);session=PoolSession.find(op.session_id)
      raise Pool::Error.new("revision_conflict") unless data["expected_session_revision"]==op.expected_session_revision && data["input_workspace_revision"]==op.input_workspace_revision
      if op.acknowledgement
        raise Pool::Error.new("acknowledgement_conflict") unless op.acknowledgement==data["decision"] && (data["decision"]=="discarded" ? data["checkpoint_id"].nil? : data["checkpoint_id"]==op.candidate_checkpoint_id)
        next op
      end
      raise Pool::Error.new("operation_not_terminal") unless Pool::Presenter.terminal?(op)
      if data["decision"]=="accepted"
        raise Pool::Error.new("result_not_publishable") unless op.publication_eligibility=="eligible" && op.checkpoint_status=="ready" && op.candidate_checkpoint_id==data["checkpoint_id"] && session.revision==op.expected_session_revision
        session.update!(revision:session.revision+1,last_accepted_checkpoint_id:op.candidate_checkpoint_id)
      else
        raise Pool::Error.new("invalid_acknowledgement",422) unless data["checkpoint_id"].nil?
      end
      op.update!(acknowledgement:data["decision"],acknowledged_at:Time.current,acknowledged_revision:session.revision)
      WorkspaceLock.where(operation_id:op.id).delete_all
      Pool::Lifecycle.event(session,"operation.acknowledged",operation:op,details:{decision:data["decision"],revision:session.revision})
      op
    end
  end
  def events
    require_scope!("execution");session=owned(PoolSession)
    expired_cursor!(session.events_first_seq)
    page(PoolEvent.where(tenant_id:@tenant.id,session_id:session.id),"events") { |e| {seq:e.id,type:e.event_type,occurred_at:e.created_at,operation_id:e.operation_id,details:e.details} }
  end
  def output
    require_scope!("execution");op=owned(Operation)
    expired_cursor!(op.output_first_seq)
    page(OutputChunk.where(tenant_id:@tenant.id,operation_id:op.id),"chunks",extra:{truncated:op.truncated,redacted:op.redacted,capture_complete:op.capture_complete}) { |c| {seq:c.id,stream:c.stream,text:c.text,received_at:c.created_at} }
  end
  private
  def authenticate!
    token=request.authorization.to_s.delete_prefix("Bearer ")
    raise Pool::Error.new("unauthorized",401) unless request.authorization.to_s.start_with?("Bearer ") && token.bytesize.between?(32,200)
    @credential=ApiCredential.find_by(digest:Pool::Auth.digest(token),revoked_at:nil)
    raise Pool::Error.new("unauthorized",401) unless @credential
    @tenant=Tenant.find(@credential.tenant_id)
    response.set_header("Cache-Control","no-store")
  end
  def require_scope!(scope)
    raise Pool::Error.new("scope_forbidden",403) unless @credential.scopes.include?(scope)
  end
  def owned(model,id=params[:id]) = model.find_by!(id:id,tenant_id:@tenant.id)
  def ensure_open!(session)
    raise Pool::Error.new("session_closed") if %w[terminating terminated failed recovering].include?(session.state) || session.expires_at<=Time.current
  end
  def body!(schema)
    raise Pool::Error.new("request_too_large",413) if request.content_length.to_i>131072
    raw=request.body.read(131073)
    raise Pool::Error.new("request_too_large",413) if raw.bytesize>131072
    Pool::Contract.validate!(schema,JSON.parse(raw))
  end
  def canonical(v)
    case v
    when Hash then v.keys.sort.to_h { |k| [k,canonical(v[k])] }
    when Array then v.map { |x| canonical(x) }
    else v
    end
  end
  def mutate(data,status,serializer:Pool::Presenter.method(:call))
    key=request.headers["Idempotency-Key"].to_s
    raise Pool::Error.new("idempotency_key_required",400) unless key.bytesize.between?(1,200)
    digest=Pool::Auth.digest(JSON.generate(canonical(data)))
    resource=nil
    @tenant.with_lock do
      existing=IdempotencyRecord.find_by(tenant_id:@tenant.id,route:request.path,key:key)
      if existing
        raise Pool::Error.new("idempotency_conflict") unless existing.digest==digest
        klass={"Artifact"=>Artifact,"PoolSession"=>PoolSession,"Operation"=>Operation,"SecretBinding"=>SecretBinding}.fetch(existing.resource_type)
        resource=klass.find_by!(id:existing.resource_id,tenant_id:@tenant.id)
        status=existing.status
      else
        resource=yield
        IdempotencyRecord.create!(tenant_id:@tenant.id,route:request.path,key:key,digest:digest,resource_type:resource.class.name,resource_id:resource.id,status:status)
      end
    end
    render json:serializer.call(resource),status:status
  end
  def expired_cursor!(floor)
    raise Pool::Error.new("cursor_expired",410) if floor && params.fetch(:after,0).to_i<floor-1
  end
  def page(scope,key,extra:{})
    after=Integer(params.fetch(:after,0));limit=Integer(params.fetch(:limit,100))
    raise Pool::Error.new("invalid_cursor",422) unless after>=0 && limit.between?(1,100)
    rows=scope.where("id > ?",after).order(:id).limit(limit+1).to_a
    more=rows.size>limit;rows=rows.first(limit)
    render json:extra.merge(key=>rows.map { |e| yield e },next_cursor:rows.last&.id || after,has_more:more)
  rescue ArgumentError,TypeError
    raise Pool::Error.new("invalid_cursor",422)
  end
end
