module Pool
  class SecretVault
    def root
      path=Pathname.new(ENV.fetch("POOL_SECRET_ROOT","/dev/shm/execution-pool-secrets"))
      # Production secrets must be memory-backed and outside exported workspace/storage.
      raise "Secret root must be under /dev/shm" unless path.absolute? && path.cleanpath==path && path.to_s.start_with?("/dev/shm/")
      raise "Unsafe secret root" if path.ascend.any?(&:symlink?)
      FileUtils.mkdir_p(path,mode:0o700)
      raise "Unsafe secret root" if path.realpath!=path || path.stat.uid!=Process.euid || (path.stat.mode & 0o077) != 0
      path
    end
    def path(binding)
      raise "Invalid secret id" unless binding.id.match?(/\Asecret_binding_[a-f0-9]{24}\z/)
      root.join(binding.id)
    end
    def put(binding,value)
      File.open(path(binding),File::WRONLY|File::CREAT|File::EXCL,0o600) { |f| f.write(value) }
    end
    def revoke(binding)
      File.unlink(path(binding)) if File.exist?(path(binding))
    end
    def consume!(binding, operation, epoch)
      binding.with_lock do
        raise Error.new("secret_unavailable",409) unless binding.state=="available" && binding.expires_at>=operation.deadline && binding.session_id==operation.session_id && binding.operation_key==operation.operation_key && binding.tenant_id==operation.tenant_id && operation.lease_epoch==epoch && File.file?(path(binding))
        value=File.open(path(binding),File::RDONLY|File::NOFOLLOW) do |file|
          raise Error.new("secret_unavailable",409) unless file.stat.file? && file.stat.uid==Process.euid && (file.stat.mode & 0o077)==0
          file.read
        end
        File.unlink(path(binding))
        binding.update!(state:"consumed",consumed_by:operation.id,consumed_epoch:epoch)
        value
      end
    end
  end
end
