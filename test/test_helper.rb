ENV["RAILS_ENV"]="test"
require_relative "../config/environment"
require "rails/test_help"
require "rubygems/package"
require "zlib"
require "tmpdir"
raise "Refusing tests outside isolated database" unless ApplicationRecord.connection_db_config.database=="execution_pool_test"
class ActionDispatch::IntegrationTest
  self.use_transactional_tests=false
  setup do
    ApplicationRecord.connection.execute("TRUNCATE tenants, runtime_templates, nodes, service_heartbeats CASCADE")
    @storage=Dir.mktmpdir("execution-pool-test-")
    @vault=Dir.mktmpdir("execution-pool-secret-test-","/dev/shm")
    ENV["POOL_STORAGE_ROOT"]=@storage;ENV["POOL_SECRET_ROOT"]=@vault
    @template=RuntimeTemplate.create!(id:"test-runtime",image_digest:"sha256:"+"a"*64,resource_profiles:{standard:{vcpus:2,memory_mib:512,disk_mib:256}},network_profiles:{offline:{deny_out:["0.0.0.0/0","::/0"]}},secret_slots:{model:{}})
    @tenant=Tenant.create!(name:"Cofounder",template_ids:[@template.id])
    @other=Tenant.create!(name:"Duke42",template_ids:[@template.id])
    @token=Pool::Auth.issue!(@tenant)
    @other_token=Pool::Auth.issue!(@other)
    @node=Node.create!(name:"test",provider:"fake",state:"ready",vcpus:2,memory_mib:512,disk_mib:256,checked_at:Time.current)
    @input=artifact_for(@tenant,archive("hello.txt"=>"hello"))
  end
  teardown do
    FileUtils.remove_entry(@storage) if @storage && File.directory?(@storage)
    FileUtils.remove_entry(@vault) if @vault && File.directory?(@vault)
  end
  def archive(files)
    raw=StringIO.new
    Gem::Package::TarWriter.new(raw) { |tar| files.each { |name,value| tar.add_file_simple(name,0o644,value.bytesize) { |io| io.write(value) } } }
    out=StringIO.new;gzip=Zlib::GzipWriter.new(out);gzip.write(raw.string);gzip.close;out.string
  end
  def artifact_for(tenant,bytes)
    artifact=Artifact.create!(tenant_id:tenant.id,kind:"workspace_input",media_type:"application/gzip",size_bytes:bytes.bytesize,sha256:Digest::SHA256.hexdigest(bytes))
    Pool::BlobStore.new.upload!(artifact,StringIO.new(bytes))
  end
  def headers(token=@token,key:SecureRandom.hex(12))
    {"Authorization"=>"Bearer #{token}","Content-Type"=>"application/json","Idempotency-Key"=>key}
  end
  def new_pool_session(task:"task-1",workspace:"workspace-1",token:@token)
    post "/v1/sessions",params:{task_key:task,task_version:"1",workspace_key:workspace,template_id:@template.id,resource_profile:"standard",network_profile:"offline"}.to_json,headers:headers(token)
    assert_response :accepted
    response.parsed_body.fetch("id")
  end
  def create_operation(session_id,input:@input,key:"step-1",secrets:[],argv:["true"],token:@token,revision:0,permission:"workspace-write")
    post "/v1/sessions/#{session_id}/operations",params:{operation_key:key,app_run_id:"app-run",expected_session_revision:revision,input_workspace_revision:"files-v1",input_artifact_id:input.id,argv:argv,permission_profile:permission,timeout_seconds:60,secret_binding_ids:secrets}.to_json,headers:headers(token,key:key)
    assert_response :accepted
    Operation.find(response.parsed_body.fetch("id"))
  end
  def ack(op,decision:"accepted",token:@token)
    post "/v1/operations/#{op.id}/acknowledgement",params:{decision:decision,checkpoint_id:decision=="accepted" ? op.reload.candidate_checkpoint_id : nil,expected_session_revision:op.expected_session_revision,input_workspace_revision:op.input_workspace_revision}.to_json,headers:headers(token)
  end
  class FakeProvider
    attr_accessor :failure,:deletion,:exit_code,:secret_output
    attr_reader :created,:executed,:deleted
    def initialize
      @created=[];@executed=[];@deleted=[];@deletion=true;@exit_code=0
    end
    def create(reservation,template,session,guard:)
      guard.call;@created<<reservation.id
      raise "create uncertain" if @failure==:create
      "fake-#{reservation.id}"
    end
    def execute(reservation,op,template,secrets,guard:,on_output:)
      @executed<<op.id
      raise "execution uncertain" if @failure==:execute
      guard.call
      {exit_code:@exit_code,stdout:@secret_output || "hello from guest\n",stderr:"",checkpoint:File.binread(Pool::BlobStore.new.path(Artifact.find(op.input_artifact_id))),result:{passed:@exit_code==0}}
    end
    def delete_and_confirm(reservation)
      @deleted<<reservation.id
      @deletion
    end
  end
end
