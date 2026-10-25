require 'test_helper'
class SecurityBoundariesTest < ActionDispatch::IntegrationTest
  test 'revoked credential cannot read a previously accessible operation' do
    op=create_operation(new_pool_session)
    ApiCredential.find_by!(digest:Pool::Auth.digest(@token)).update!(revoked_at:Time.current)
    get "/v1/operations/#{op.id}",headers:headers
    assert_response :unauthorized
  end

  test 'other tenant cannot cancel acknowledge heartbeat or inspect logs and events' do
    op=create_operation(new_pool_session)
    %w[cancel heartbeat acknowledgement].each do |action|
      payload=action=="acknowledgement" ? {decision:"discarded",checkpoint_id:nil,expected_session_revision:0,input_workspace_revision:"files-v1"} : {}
      post "/v1/operations/#{op.id}/#{action}",params:payload.to_json,headers:headers(@other_token)
      assert_response :not_found
    end
    ["/v1/operations/#{op.id}/output","/v1/sessions/#{op.session_id}/events"].each do |path|
      get path,headers:headers(@other_token)
      assert_response :not_found
    end
    assert_equal 'queued',op.reload.state
  end

  test 'secret storage rejects parent traversal and symlink ancestors' do
    ENV['POOL_SECRET_ROOT']='/dev/shm/../../tmp/forbidden-openfly-vault'
    assert_raises(RuntimeError) { Pool::SecretVault.new.root }
    link=File.join(@vault,'redirect');File.symlink(@storage,link)
    ENV['POOL_SECRET_ROOT']=File.join(link,'nested')
    assert_raises(RuntimeError) { Pool::SecretVault.new.root }
  end

  test 'secret consumption refuses symlink and stale fencing epoch' do
    op=create_operation(new_pool_session)
    op.update!(lease_epoch:123)
    binding=SecretBinding.create!(tenant_id:@tenant.id,session_id:op.session_id,operation_key:op.operation_key,slot:'model',expires_at:1.hour.from_now)
    vault=Pool::SecretVault.new
    vault.put(binding,'test-only-value')
    assert_raises(Pool::Error) { vault.consume!(binding,op,122) }
    File.unlink(vault.path(binding))
    target=File.join(@storage,'target');File.write(target,'private');File.chmod(0o600,target)
    File.symlink(target,vault.path(binding))
    assert_raises(Errno::ELOOP) { vault.consume!(binding,op,123) }
    assert_equal 'available',binding.reload.state
    assert_equal 'private',File.read(target)
  end

  test 'cancel fences the old writer even when its lease remains fresh' do
    op=create_operation(new_pool_session)
    worker=Pool::Worker.new(provider:FakeProvider.new,runner_id:'runner')
    op=Pool::Scheduler.new.claim('runner');epoch=op.lease_epoch
    Pool::Lifecycle.cancel!(op)
    assert_raises(Pool::Error) { worker.guard!(op,epoch) }
    assert op.reload.lease_epoch>epoch
    assert_equal 'unknown',op.execution_status
  end

  test 'healthy saturated pool remains ready and labels capacity busy' do
    create_operation(new_pool_session)
    Pool::Scheduler.new.claim('runner')
    Pool::Heartbeat.new('execution').pulse;Pool::Heartbeat.new('maintenance').pulse
    get '/ready'
    assert_response :ok
    assert_equal 'busy',response.parsed_body['capacity']
  end

  test 'inaccessible storage makes readiness fail without disclosing its path' do
    original=ENV['POOL_STORAGE_ROOT'];ENV['POOL_STORAGE_ROOT']='/proc/openfly-unwritable'
    get '/ready'
    assert_response :service_unavailable
    refute_includes response.body,'/proc/'
  ensure
    ENV['POOL_STORAGE_ROOT']=original
  end
end
