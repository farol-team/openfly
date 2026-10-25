require "test_helper"
class RecoveryTest < ActionDispatch::IntegrationTest
  test "missing secret before dispatch releases unused capacity without provider calls" do
    session_id=new_pool_session
    binding=SecretBinding.create!(tenant_id:@tenant.id,session_id:session_id,operation_key:"step-1",slot:"model",expires_at:1.hour.from_now)
    op=create_operation(session_id,secrets:[binding.id])
    provider=FakeProvider.new
    Pool::Worker.new(provider:provider).run_once
    assert_equal "secret_unavailable",op.reload.error_code
    assert_equal "not_started",op.execution_status
    assert_empty provider.created
    assert_empty provider.deleted
    assert Reservation.find(op.reservation_id).released_at
    assert_equal "confirmed",PoolSession.find(session_id).cleanup_status
    assert WorkspaceLock.exists?(operation_id:op.id)
  end

  test "uncertain create still quarantines capacity" do
    op=create_operation(new_pool_session)
    provider=FakeProvider.new;provider.failure=:create;provider.deletion=false
    worker=Pool::Worker.new(provider:provider);worker.run_once;worker.reconcile!
    assert_equal 1,provider.created.size
    reservation=Reservation.find(op.reload.reservation_id)
    assert_equal "quarantined",reservation.state
    assert_nil reservation.released_at
  end
  class RecoverableProvider < FakeProvider
    attr_accessor :recovery_bytes,:recovery_error
    attr_reader :calls
    def initialize
      super
      @calls=[]
    end
    def recover(reservation)
      @calls<<:recover
      raise "capture unavailable" if recovery_error
      recovery_bytes
    end
    def delete_and_confirm(reservation)
      @calls<<:delete
      super
    end
  end
  test "uncertain execution captures protected recovery before deletion without replay" do
    op=create_operation(new_pool_session)
    provider=RecoverableProvider.new
    provider.failure=:execute
    provider.recovery_bytes=archive("partial.txt"=>"partial work")
    worker=Pool::Worker.new(provider:provider)
    worker.run_once
    assert_equal "unknown",op.reload.execution_status
    worker.reconcile!
    assert_equal [:recover,:delete],provider.calls
    recovery=Artifact.find_by!(operation_id:op.id,kind:"recovery")
    assert recovery.recovery_only
    assert_nil recovery.retention_expires_at
    assert_equal "ineligible",op.reload.publication_eligibility
    assert_equal [op.id],provider.executed
    assert Reservation.find(op.reservation_id).released_at
  end
  test "unavailable recovery quarantines capacity and does not delete guest" do
    op=create_operation(new_pool_session)
    provider=RecoverableProvider.new;provider.failure=:execute;provider.recovery_error=true
    worker=Pool::Worker.new(provider:provider);worker.run_once;worker.reconcile!
    assert_equal [:recover],provider.calls
    reservation=Reservation.find(op.reload.reservation_id)
    assert_equal "quarantined",reservation.state
    assert_nil reservation.released_at
    assert WorkspaceLock.exists?(operation_id:op.id)
  end
  test "failed upload metadata never permits deletion on the next reconciliation" do
    op=create_operation(new_pool_session)
    provider=RecoverableProvider.new;provider.failure=:execute
    provider.recovery_bytes="invalid archive"
    worker=Pool::Worker.new(provider:provider);worker.run_once
    worker.reconcile!
    assert Artifact.exists?(operation_id:op.id,kind:"recovery",state:"pending")
    Reservation.find(op.reload.reservation_id).update!(next_reconcile_at:1.second.ago)
    worker.reconcile!
    assert_equal [:recover,:recover],provider.calls
    assert_nil Reservation.find(op.reload.reservation_id).released_at
    provider.recovery_bytes=archive("recovered.txt"=>"captured")
    Reservation.find(op.reservation_id).update!(next_reconcile_at:1.second.ago)
    worker.reconcile!
    assert_equal [:recover,:recover,:recover,:delete],provider.calls
    assert Artifact.exists?(operation_id:op.id,kind:"recovery",state:"ready",recovery_only:true)
  end

end
