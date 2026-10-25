require "net/http"
require "json"
require "securerandom"
require "digest"
module ExecutionPool
  class Client
    class Error < StandardError
      attr_reader :code,:status
      def initialize(code,status)
        @code,@status=code,status
        super("Execution Pool #{code} (#{status})")
      end
    end
    TERMINAL=%w[succeeded failed canceled timed_out interrupted unknown].freeze
    def initialize(url:,token:)
      @url=URI(url);@token=token
      raise ArgumentError,"HTTPS or loopback required" unless @url.scheme=="https" || (@url.scheme=="http" && %w[127.0.0.1 localhost ::1].include?(@url.hostname))
      raise ArgumentError,"Invalid API URL" if @url.userinfo || @url.query || @url.fragment || ![nil,"","/"].include?(@url.path)
    end
    def request(method,path,body:nil,key:nil,binary:false)
      raise ArgumentError,"Invalid path" unless path.start_with?("/v1/") && !path.include?("..")
      klass={"GET"=>Net::HTTP::Get,"POST"=>Net::HTTP::Post,"PUT"=>Net::HTTP::Put,"DELETE"=>Net::HTTP::Delete}.fetch(method)
      key ||= SecureRandom.uuid if method=="POST"
      attempts=0
      begin
        attempts+=1
        req=klass.new(path)
        req["Authorization"]="Bearer #{@token}"
        req["Content-Type"]=binary ? "application/octet-stream" : "application/json"
        req["Idempotency-Key"]=key if key
        req.body=binary ? body : JSON.generate(body) if body
        response=Net::HTTP.start(@url.hostname,@url.port,use_ssl:@url.scheme=="https",open_timeout:5,read_timeout:60) { |http| http.request(req) }
        unless response.code.to_i.between?(200,299)
          code=JSON.parse(response.body).dig("error","code") rescue "unavailable"
          raise Error.new(code || "unavailable",response.code.to_i)
        end
        return nil if response.code=="204"
        response["Content-Type"].to_s.include?("application/json") ? JSON.parse(response.body) : response.body
      rescue IOError,SystemCallError,Timeout::Error
        # Same idempotency key; never resubmit a command with a new identity after network uncertainty.
        retry if attempts<3
        raise Error.new("transport_unavailable",503)
      end
    end
    def upload(bytes,kind:"workspace_input",key:SecureRandom.uuid)
      metadata={kind:kind,media_type:kind=="operation_request" ? "application/json" : "application/gzip",size_bytes:bytes.bytesize,sha256:Digest::SHA256.hexdigest(bytes)}
      artifact=request("POST","/v1/artifacts",body:metadata,key:key)
      request("PUT","/v1/artifacts/#{artifact.fetch('id')}/content",body:bytes,binary:true)
      artifact.fetch("id")
    end
    def wait(operation_id,cancel_if:nil,poll_seconds:1)
      heartbeat_at=0
      loop do
        operation=request("GET","/v1/operations/#{operation_id}")
        return operation if TERMINAL.include?(operation.fetch("state"))
        if cancel_if&.call
          request("POST","/v1/operations/#{operation_id}/cancel",body:{},key:"cancel-#{operation_id}")
          return request("GET","/v1/operations/#{operation_id}")
        end
        now=Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if now-heartbeat_at>=15
          begin
            request("POST","/v1/operations/#{operation_id}/heartbeat",body:{})
          rescue Error=>error
            raise unless error.code=="lease_inactive"
            next
          end
          heartbeat_at=now
        end
        sleep poll_seconds
      end
    end
  end
end
