require "test_helper"
class DockerExecutionTest < ActionDispatch::IntegrationTest
  test "real guest execution streams logs retains files enforces read only and cleans up" do
    skip "Explicit Docker acceptance only; not KVM certification" unless ENV["POOL_DOCKER_INTEGRATION"]=="1"
    ENV["POOL_ALLOW_DOCKER_TEST"]="1"
    image,status=Open3.capture2("docker","image","inspect","-f","{{.Id}}",ENV.fetch("POOL_TEST_IMAGE","openfly-runtime:test"))
    assert status.success?
    @template.update_column(:image_digest,image.strip) # Test fixture only, before any session exists.
    @node.update!(provider:"docker_test",config:{template_ids:[@template.id],network_profiles:["offline"]})
    session=new_pool_session
    script="import pathlib,time,json,os; pathlib.Path('large.bin').write_bytes(b'x' * 2097152); print('first line',flush=True); time.sleep(3); pathlib.Path('hello.txt').chmod(0o600); os.symlink('/opt/execution-pool/guest.py','/tmp/execution-pool-output.tar.gz'); json.dump({'passed':True},open('/run/task/result.json','w'))"
    first=create_operation(session,argv:["python3","-c",script])
    worker=Pool::Worker.new(provider:Pool::Bridge.new)
    thread=Thread.new { ApplicationRecord.connection_pool.with_connection { worker.run_once } }
    deadline=Time.now+100;observed_live=false
    while thread.alive? && Time.now<deadline
      observed_live ||= ApplicationRecord.uncached { OutputChunk.where(operation_id:first.id).exists? && !Pool::Presenter.terminal?(first.reload) }
      sleep 0.2
    end
    thread.join(5)
    refute thread.alive?,"Execution did not finish"
    assert_equal "succeeded",first.reload.state,first.attributes.slice("state","error_code").inspect
    assert observed_live,"Expected durable output before terminal completion"
    assert_equal "ready",first.checkpoint_status
    ack(first);assert_response :success
    input=Artifact.find(first.candidate_checkpoint_id)
    read_script="import pathlib; assert pathlib.Path('hello.txt').read_text()=='hello'; assert pathlib.Path('large.bin').stat().st_size==2097152; print('read works'); pathlib.Path('hello.txt').write_text('forbidden')"
    second=create_operation(session,key:"read-check",revision:1,input:input,permission:"workspace-read",argv:["python3","-c",read_script])
    worker.run_once
    assert_equal "failed",second.reload.state
    second_output=OutputChunk.where(operation_id:second.id).pluck(:text).join
    assert_includes second_output,"PermissionError"
    refute_includes second_output,"first line"
    assert_equal first.generation,second.generation
    assert_equal 1,Reservation.count
    ack(second);assert_response :success
    delete "/v1/sessions/#{session}",headers:headers
    worker.reconcile!
    assert_equal "terminated",PoolSession.find(session).state
    assert_equal 0,Reservation.where(released_at:nil).count
  ensure
    # Test-only cleanup of our own labelled guests, never other projects.
    if defined?(session) && session
      Reservation.where(session_id:session,released_at:nil).each { |r| Pool::Bridge.new.delete_and_confirm(r) rescue nil }
    end
    ENV.delete("POOL_ALLOW_DOCKER_TEST")
  end
end
