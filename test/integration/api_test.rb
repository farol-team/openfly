require "test_helper"
class ApiTest < ActionDispatch::IntegrationTest
  test "auth and scopes protect all tenant data" do
    get "/v1/templates"
    assert_response :unauthorized
    token=Pool::Auth.issue!(@tenant,scopes:["artifacts"])
    get "/v1/templates",headers:headers(token)
    assert_response :forbidden
    session=new_pool_session
    get "/v1/sessions/#{session}",headers:headers(@other_token)
    assert_response :not_found
    get "/v1/artifacts/#{@input.id}/content",headers:headers(@other_token)
    assert_response :not_found
    get "/v1/quota",headers:headers
    assert_response :success
    assert_equal "no-store",response.headers["Cache-Control"]
  end
  test "idempotent create survives retries and rejects changed body" do
    body={task_key:"x",task_version:"1",workspace_key:"w",template_id:@template.id,resource_profile:"standard",network_profile:"offline"}
    2.times { post "/v1/sessions",params:body.to_json,headers:headers(key:"same");assert_response :accepted }
    assert_equal 1,PoolSession.count
    post "/v1/sessions",params:body.merge(task_key:"other").to_json,headers:headers(key:"same")
    assert_response :conflict
    assert_equal "idempotency_conflict",response.parsed_body.dig("error","code")
    refute IdempotencyRecord.column_names.include?("body")
  end
  test "same task keys across tenants do not collide" do
    a=new_pool_session
    b=new_pool_session(token:@other_token)
    refute_equal a,b
    assert_equal 2,PoolSession.count
  end
  test "uploads validate hashes and archive traversal and never expose pending bytes" do
    bytes=archive("../outside"=>"bad")
    post "/v1/artifacts",params:{kind:"workspace_input",media_type:"application/gzip",size_bytes:bytes.bytesize,sha256:Digest::SHA256.hexdigest(bytes)}.to_json,headers:headers
    assert_response :created
    id=response.parsed_body.fetch("id")
    put "/v1/artifacts/#{id}/content",params:bytes,headers:headers.merge("Content-Type"=>"application/octet-stream")
    assert_response :unprocessable_entity
    get "/v1/artifacts/#{id}/content",headers:headers
    assert_response :conflict
    assert_equal "pending",Artifact.find(id).state
    get "/v1/artifacts/#{@input.id}/content",headers:headers
    assert_response :success
    assert_equal @input.sha256,Digest::SHA256.hexdigest(response.body)
  end
  test "workspace lock held through terminal until acknowledgement" do
    session=new_pool_session
    op=create_operation(session)
    provider=FakeProvider.new
    Pool::Worker.new(provider:provider).run_once
    assert_equal "succeeded",op.reload.state
    assert WorkspaceLock.exists?(operation_id:op.id)
    second=new_pool_session(task:"other-task")
    post "/v1/sessions/#{second}/operations",params:{operation_key:"step",app_run_id:"r",expected_session_revision:0,input_workspace_revision:"files-v1",input_artifact_id:@input.id,argv:["true"],permission_profile:"workspace-write",timeout_seconds:60}.to_json,headers:headers
    assert_response :conflict
    ack(op)
    assert_response :success
    assert_equal 1,response.parsed_body["session_revision"]
    refute WorkspaceLock.exists?(operation_id:op.id)
    get "/v1/operations/#{op.id}",headers:headers
    assert_response :success
    assert Pool::Contract.validate!("Operation",response.parsed_body)
  end
  test "terminal result can be acknowledged after session close and VM deletion" do
    session=new_pool_session
    op=create_operation(session)
    provider=FakeProvider.new;worker=Pool::Worker.new(provider:provider);worker.run_once
    delete "/v1/sessions/#{session}",headers:headers
    assert_response :accepted
    worker.reconcile!
    assert_equal "terminated",PoolSession.find(session).state
    ack(op)
    assert_response :success
    ack(op)
    assert_response :success
    assert_equal 1,PoolSession.find(session).revision
  end
  test "failed check retains VM for corrective operation and fences by fresh epoch" do
    session=new_pool_session
    provider=FakeProvider.new;provider.exit_code=1;worker=Pool::Worker.new(provider:provider)
    first=create_operation(session);worker.run_once
    assert_equal "failed",first.reload.state
    ack(first);assert_response :success
    second=create_operation(session,key:"step-2",revision:1)
    provider.exit_code=0;worker.run_once
    assert_equal "succeeded",second.reload.state
    assert_equal 1,provider.created.size
    assert second.lease_epoch>first.lease_epoch
  end
  test "unknown provider execution never retries and holds capacity until proven deletion" do
    op=create_operation(new_pool_session)
    provider=FakeProvider.new;provider.failure=:execute;provider.deletion=false
    worker=Pool::Worker.new(provider:provider);worker.run_once
    assert_equal "unknown",op.reload.execution_status
    assert_equal "unknown",op.state
    worker.run_once
    assert_equal [op.id],provider.executed
    assert_equal 1,Reservation.where(released_at:nil).count
    ack(op)
    assert_response :conflict
    provider.deletion=true;worker.reconcile!
    assert_equal 0,Reservation.where(released_at:nil).count
  end
  test "uncertain create does not dispatch command and is quarantined" do
    op=create_operation(new_pool_session)
    provider=FakeProvider.new;provider.failure=:create;provider.deletion=false
    worker=Pool::Worker.new(provider:provider);worker.run_once;worker.reconcile!
    assert_empty provider.executed
    assert_equal "not_started",op.reload.execution_status
    assert_equal "quarantined",Reservation.first.state
  end
  test "secrets are ephemeral consumed once and not stored in SQL or output" do
    session=new_pool_session
    post "/v1/secret-bindings",params:{session_id:session,operation_key:"step-1",slot:"model",value:"synthetic-sensitive-value",ttl_seconds:3600}.to_json,headers:headers(key:"secret")
    assert_response :created
    binding=SecretBinding.find(response.parsed_body["id"])
    refute_includes response.body,"synthetic-sensitive-value"
    op=create_operation(session,secrets:[binding.id])
    provider=FakeProvider.new;provider.secret_output="synthetic-sensitive-value"
    Pool::Worker.new(provider:provider).run_once
    assert_equal "consumed",binding.reload.state
    refute File.exist?(Pool::SecretVault.new.path(binding))
    get "/v1/operations/#{op.id}/output",headers:headers
    assert_response :success
    refute_includes response.body,"synthetic-sensitive-value"
    assert_includes response.body,"REDACTED"
    assert_raises(Pool::Error) { Pool::SecretVault.new.consume!(binding,op,op.lease_epoch) }
  end
  test "expired queued lease cannot be renewed or secretly executed" do
    op=create_operation(new_pool_session)
    op.update!(lease_expires_at:1.second.ago)
    post "/v1/operations/#{op.id}/heartbeat",headers:headers
    assert_response :conflict
    provider=FakeProvider.new;Pool::Worker.new(provider:provider).run_once
    assert_empty provider.executed
    assert_equal "not_started",op.reload.execution_status
    assert Pool::Presenter.terminal?(op)
  end
  test "concurrent workers cannot reserve the same final seat" do
    a=create_operation(new_pool_session)
    other_input=artifact_for(@other,archive("other"=>"x"))
    b=create_operation(new_pool_session(token:@other_token),token:@other_token,input:other_input)
    results=2.times.map { |i| Thread.new { ApplicationRecord.connection_pool.with_connection { Pool::Scheduler.new.claim("w#{i}") } } }.map(&:value)
    assert_equal 1,results.compact.size
    assert_equal 1,Reservation.where(released_at:nil).count
    assert_equal 1,Operation.where(state:"queued").count
  end
  test "database rejects a cross tenant artifact reference even in trusted code" do
    session=new_pool_session
    other_input=artifact_for(@other,archive("other"=>"x"))
    op=create_operation(session)
    assert_raises(ActiveRecord::InvalidForeignKey) { op.update!(input_artifact_id:other_input.id) }
  end
  test "bounded ordered logs and lifecycle events have resumable cursors" do
    op=create_operation(new_pool_session)
    Pool::Worker.new(provider:FakeProvider.new).run_once
    get "/v1/operations/#{op.id}/output?limit=1",headers:headers
    assert_response :success
    assert_equal 1,response.parsed_body["chunks"].size
    cursor=response.parsed_body["next_cursor"]
    get "/v1/operations/#{op.id}/output?after=#{cursor}",headers:headers
    assert_empty response.parsed_body["chunks"]
    get "/v1/sessions/#{op.session_id}/events",headers:headers
    assert_response :success
    assert response.parsed_body["events"].any? { |e| e["type"]=="operation.succeeded" }
  end
end
