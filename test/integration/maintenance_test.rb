require 'test_helper'
class MaintenanceTest < ActionDispatch::IntegrationTest
  test 'readiness requires both workers but capacity is independent' do
    get '/live'; assert_response :ok
    get '/ready'; assert_response :service_unavailable
    Pool::Heartbeat.new('execution').pulse
    Pool::Heartbeat.new('maintenance').pulse
    get '/ready'; assert_response :ok
    assert_equal 'available',response.parsed_body['capacity']
    @node.update!(state:'offline')
    get '/ready'; assert_response :ok
    assert_equal 'unavailable',response.parsed_body['capacity']
    ServiceHeartbeat.update_all(seen_at:1.minute.ago)
    get '/ready'; assert_response :service_unavailable
  end

  test 'failed cleanup backs off without releasing capacity or replaying execution' do
    op=create_operation(new_pool_session)
    provider=FakeProvider.new;provider.failure=:execute;provider.deletion=false
    worker=Pool::Worker.new(provider:provider)
    worker.run_once;worker.reconcile!
    reservation=Reservation.find(op.reload.reservation_id)
    assert_equal 1,reservation.reconcile_attempts
    assert reservation.next_reconcile_at>Time.current
    assert_nil reservation.released_at
    worker.reconcile!
    assert_equal 1,provider.deleted.size
    assert_equal 1,provider.executed.size
  end

  test 'reservation lock excludes cleanup on another database connection' do
    op=create_operation(new_pool_session)
    provider=FakeProvider.new;provider.failure=:execute
    worker=Pool::Worker.new(provider:provider);worker.run_once
    Pool::ReservationLock.with(op.reload.reservation_id) do
      Thread.new { ApplicationRecord.connection_pool.with_connection { worker.reconcile! } }.value
      assert_empty provider.deleted
    end
    worker.reconcile!
    assert_equal 1,provider.deleted.size
  end

  test 'stale observed VM state is unknown rather than presence inferred from database' do
    op=create_operation(new_pool_session)
    Pool::Worker.new(provider:FakeProvider.new).run_once
    session=PoolSession.find(op.session_id)
    assert_equal true,Pool::Presenter.call(session)['vm_present']
    Reservation.find(op.reload.reservation_id).update!(observed_at:2.minutes.ago)
    data=Pool::Presenter.call(session)
    assert_nil data['vm_present']
    assert_equal 'unknown',data['vm_state']
    assert data['vm_observed_at']
  end
  test 'blocked provider cleanup does not block expiry of another session' do
    op=create_operation(new_pool_session)
    provider=FakeProvider.new;provider.failure=:execute
    Pool::Worker.new(provider:provider).run_once
    started=Queue.new;release=Queue.new
    provider.define_singleton_method(:delete_and_confirm) { |_reservation| started << true;release.pop;true }
    maintenance=Pool::Maintenance.new(provider:provider)
    maintenance.tick
    Timeout.timeout(5) { started.pop }
    second=PoolSession.find(new_pool_session(task:'another',workspace:'another'))
    second.update!(expires_at:1.second.ago)
    maintenance.tick
    assert_equal 'terminated',second.reload.state
  ensure
    release << true if release
    maintenance&.shutdown
  end

  test 'operator diagnostics require explicit scope and omit node configuration' do
    @node.update!(config:{environment_file:'/private/secret-file'})
    get '/v1/operator/status',headers:headers
    assert_response :forbidden
    token=Pool::Auth.issue!(@tenant,scopes:['operator'])
    get '/v1/operator/status',headers:headers(token)
    assert_response :ok
    refute_includes response.body,'secret-file'
    assert response.parsed_body.key?('quarantined_vcpus')
  end

  test 'process crash releases reservation fencing lock without command replay' do
    marker=File.join(@storage,'lock-acquired')
    key='crash-test-reservation'
    code="require_relative 'config/environment';Pool::ReservationLock.with(ARGV[0]) { File.write(ARGV[1],'ready'); sleep 30 }"
    pid=Process.spawn({'RAILS_ENV'=>'test'},RbConfig.ruby,'-e',code,key,marker,out:File::NULL,err:File::NULL)
    Timeout.timeout(10) { sleep 0.05 until File.exist?(marker) }
    refute Pool::ReservationLock.with(key) { flunk 'Concurrent ownership' }
    Process.kill('KILL',pid);Process.wait(pid);pid=nil
    acquired=false
    Timeout.timeout(5) do
      until acquired
        acquired=Pool::ReservationLock.with(key) { true }
        sleep 0.05 unless acquired
      end
    end
    assert acquired
  ensure
    Process.kill('KILL',pid) rescue nil if pid
    Process.wait(pid) rescue nil if pid
  end

  test 'provider observation failure is unknown and never frees quota' do
    op=create_operation(new_pool_session)
    provider=FakeProvider.new
    Pool::Worker.new(provider:provider).run_once
    reservation=Reservation.find(op.reload.reservation_id)
    provider.define_singleton_method(:observe) { |_reservation| raise 'upstream private error' }
    Pool::Observer.new(provider:provider).run(reservation.id)
    assert_equal 'unknown',reservation.reload.observed_state
    assert_nil reservation.released_at
    provider.define_singleton_method(:observe) { |_reservation| 'absent' }
    Pool::Observer.new(provider:provider).run(reservation.id)
    assert_equal 'reconciling',reservation.reload.state
    assert_nil reservation.released_at
  end

end
