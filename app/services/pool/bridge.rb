require "open3"
require "tmpdir"
module Pool
  class Bridge
    def initialize
      @root=BlobStore.new.root.join("staging")
      FileUtils.mkdir_p(@root,mode:0o700)
    end
    def create(reservation,template,session,guard:)
      invoke("create",reservation,template:template,session:session,guard:guard).fetch("provider_id")
    end
    def execute(reservation,op,template,values,guard:,on_output:)
      Dir.mktmpdir("operation-",@root) do |directory|
        input=BlobStore.new.path(Artifact.find(op.input_artifact_id)).to_s
        request=op.request_artifact_id && BlobStore.new.path(Artifact.find(op.request_artifact_id)).to_s
        data=invoke("execute",reservation,template:template,session:PoolSession.find(op.session_id),guard:guard,on_output:on_output,extra:{operation:op.attributes.slice(*%w[id argv cwd permission_profile timeout_seconds deadline]),input_path:input,request_path:request,output_dir:directory,secrets:values})
        checkpoint=File.join(directory,"checkpoint.tar.gz")
        raise Error.new("checkpoint_missing") unless File.file?(checkpoint) && !File.symlink?(checkpoint) && File.size(checkpoint)<=BlobStore::MAX_BYTES
        {exit_code:data.fetch("exit_code"),stdout:data.fetch("stdout",""),stderr:data.fetch("stderr",""),result:data["result"],checkpoint:File.binread(checkpoint),error_code:data["error_code"],truncated:data["truncated"]}
      end
    end
    def recover(reservation)
      Dir.mktmpdir("recovery-",@root) do |directory|
        data=invoke("recover",reservation,extra:{output_dir:directory})
        next nil unless data.fetch("exists")
        file=File.join(directory,"recovery.tar.gz")
        raise Error.new("unsafe_recovery") if File.symlink?(file) || File.size(file)>BlobStore::MAX_BYTES
        File.binread(file)
      end
    end
    def observe(reservation)
      invoke("observe",reservation).fetch("state")
    end
    def delete_and_confirm(reservation)
      invoke("delete",reservation).fetch("confirmed") == true
    end
    def invoke(action,reservation,template:nil,session:nil,guard:nil,on_output:nil,extra:{})
      node=Node.find(reservation.node_id)
      raise Error.new("unsupported_provider") unless %w[cubesandbox docker_test].include?(node.provider)
      raise Error.new("test_provider_disabled") if node.provider=="docker_test" && (Rails.env.production? || ENV["POOL_ALLOW_DOCKER_TEST"]!="1")
      payload={action:action,node:node.attributes.slice(*%w[id provider config]),reservation:reservation.attributes.slice(*%w[id provider_id creation_key vcpus memory_mib disk_mib]),template:template&.attributes&.slice(*%w[id image_digest network_profiles secret_slots]),session:session&.attributes&.slice(*%w[id network_profile idle_timeout_seconds expires_at])}.merge(extra)
      output=String.new;status=nil;result=nil;diagnostic=nil
      started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      python=ENV.fetch("POOL_PYTHON","python3")
      Open3.popen3(python,Rails.root.join("runtime/provider.py").to_s,pgroup:true) do |stdin,stdout,stderr,thread|
        stdin.write(JSON.generate(payload));stdin.close
        deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+((extra[:operation] || {})["timeout_seconds"].to_i+240).clamp(240,2040)
        streams=[stdout,stderr]
        while streams.any?
          guard&.call
          raise Error.new("provider_timeout") if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
          (IO.select(streams,nil,nil,1)&.first || []).each do |io|
            begin
              data=io.read_nonblock(65536)
              if io==stdout
                output<<data
                while (index=output.index("\n"))
                  line=output.slice!(0,index+1)
                  raise Error.new("provider_response_too_large") if line.bytesize>4*1024*1024
                  message=JSON.parse(line)
                  if message["type"]=="output"
                    on_output&.call(message.fetch("data"))
                  elsif message["type"]=="error"
                    data=message.fetch("data")
                    allowed=%w[provider_initialize_failed provider_create_failed provider_execute_failed provider_recover_failed provider_delete_failed provider_observe_failed]
                    raise Error.new("invalid_provider_response") unless allowed.include?(data["code"])
                    diagnostic=data["code"]
                  elsif message["type"]=="result"
                    result=message.fetch("data")
                  else
                    raise Error.new("invalid_provider_response")
                  end
                end
              end
              raise Error.new("provider_response_too_large") if output.bytesize>4*1024*1024
            rescue EOFError
              streams.delete(io)
            end
          end
        end
        status=thread.value
      rescue StandardError
        Process.kill("KILL",-thread.pid) rescue nil
        thread.join
        raise
      end
      duration=((Process.clock_gettime(Process::CLOCK_MONOTONIC)-started)*1000).round
      session_record=PoolSession.find(reservation.session_id)
      op=Operation.where(reservation_id:reservation.id).order(created_at: :desc).first
      Lifecycle.event(session_record,"provider.#{action}",operation:op,details:{code:diagnostic || (status&.success? ? "ok" : "provider_failed"),duration_ms:duration,reservation_id:reservation.id,request_id:op&.request_id})
      raise Error.new(diagnostic || "provider_failed") unless status&.success?
      raise Error.new("missing_provider_result") unless result
      result
    end
  end
end
