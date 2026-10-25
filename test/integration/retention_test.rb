require "test_helper"
class RetentionTest < ActionDispatch::IntegrationTest
  test "pending ack protects artifacts and accepted latest survives normal retention" do
    op=create_operation(new_pool_session)
    Pool::Worker.new(provider:FakeProvider.new).run_once
    input=Artifact.find(op.input_artifact_id);output=Artifact.find(op.reload.candidate_checkpoint_id)
    input.update!(retention_expires_at:1.day.ago);output.update!(retention_expires_at:1.day.ago)
    Pool::Retention.new.run
    assert_equal "ready",input.reload.state
    assert_equal "ready",output.reload.state
    ack(op);assert_response :success
    Pool::Retention.new.run
    assert_equal "expired",input.reload.state
    assert_equal "ready",output.reload.state
    get "/v1/artifacts/#{input.id}/content",headers:headers
    assert_response :gone
  end
  test "expired secrets are removed and expired logs are not silently empty" do
    session=new_pool_session
    post "/v1/secret-bindings",params:{session_id:session,operation_key:"unused",slot:"model",value:"temporary-test-secret",ttl_seconds:60}.to_json,headers:headers
    assert_response :created
    binding=SecretBinding.find(response.parsed_body["id"])
    binding.update!(expires_at:1.second.ago)
    op=create_operation(session)
    Pool::Worker.new(provider:FakeProvider.new).run_once
    ack(op);assert_response :success
    op.update!(acknowledged_at:8.days.ago)
    Pool::Retention.new.run
    assert_equal "expired",binding.reload.state
    refute File.exist?(Pool::SecretVault.new.path(binding))
    get "/v1/operations/#{op.id}/output",headers:headers
    assert_response :gone
    assert_equal "cursor_expired",response.parsed_body.dig("error","code")
  end
end
