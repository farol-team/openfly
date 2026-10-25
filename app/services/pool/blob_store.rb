require "digest"
require "tempfile"
require "open3"
module Pool
  class BlobStore
    MAX_BYTES = 256 * 1024 * 1024
    def root
      Pathname.new(ENV.fetch("POOL_STORAGE_ROOT", Rails.root.join("storage").to_s)).tap { |p| FileUtils.mkdir_p(p, mode: 0o700) }
    end
    def path(artifact)
      raise Error.new("invalid_artifact",422) unless artifact.id.match?(/\Aartifact_[a-f0-9]{24}\z/)
      root.join(artifact.id)
    end
    def upload!(artifact, io)
      raise Error.new("artifact_expired",410) if artifact.state == "expired"
      temp = Tempfile.new("upload-",root,binmode:true)
      digest = Digest::SHA256.new
      count=0
      while (chunk=io.read(65536))
        break if chunk.empty?
        count+=chunk.bytesize
        raise Error.new("artifact_too_large",413) if count>artifact.size_bytes || count>MAX_BYTES
        temp.write(chunk);digest.update(chunk)
      end
      raise Error.new("checksum_mismatch",422) unless count==artifact.size_bytes && digest.hexdigest==artifact.sha256
      temp.flush;temp.fsync
      if artifact.kind == "operation_request" || artifact.kind == "result"
        raise Error.new("invalid_json_artifact",422) if count>1048576
        raise Error.new("invalid_json_artifact",422) unless JSON.parse(File.read(temp.path)).is_a?(Hash)
      else
        validate_archive!(temp.path)
      end
      artifact.with_lock do
        raise Error.new("artifact_expired",410) if artifact.state == "expired"
        unless artifact.state == "ready"
          File.rename(temp.path,path(artifact))
          File.open(root,File::RDONLY) { |f| f.fsync }
          artifact.update!(state:"ready")
        end
      end
      artifact
    rescue JSON::ParserError, Encoding::InvalidByteSequenceError
      raise Error.new("invalid_json_artifact",422)
    ensure
      temp&.close!
    end
    def validate_archive!(file)
      _output, status = Open3.capture2e("python3",Rails.root.join("runtime/archive_cli.py").to_s,"validate",file.to_s)
      raise Error.new("unsafe_archive",422) unless status.success?
    end
    def internal!(operation,kind,bytes)
      artifact=Artifact.create!(tenant_id:operation.tenant_id,operation_id:operation.id,kind:kind,media_type:kind=="result" ? "application/json" : "application/gzip",size_bytes:bytes.bytesize,sha256:Digest::SHA256.hexdigest(bytes),retention_expires_at:7.days.from_now)
      upload!(artifact,StringIO.new(bytes))
    end
  end
end
