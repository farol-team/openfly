require "tempfile"
module Pool
  class Readiness
    def call
      ApplicationRecord.connection.select_value("SELECT 1")
      roles=ServiceHeartbeat.where("seen_at > ?",20.seconds.ago).distinct.pluck(:role)
      checks={database:true,execution:roles.include?("execution"),maintenance:roles.include?("maintenance"),
              storage:writable?(BlobStore.new.root),secrets:writable?(ENV.fetch("POOL_SECRET_ROOT"))}
      nodes=Node.where(state:"ready").where("checked_at > ?",90.seconds.ago)
      capacity=nodes.any? do |node|
        used=Reservation.where(node_id:node.id,released_at:nil)
        node.vcpus>used.sum(:vcpus) && node.memory_mib>used.sum(:memory_mib) && node.disk_mib>used.sum(:disk_mib)
      end
      {ready:checks.values.all?,checks:checks,capacity:nodes.empty? ? "unavailable" : (capacity ? "available" : "busy")}
    rescue StandardError
      {ready:false,checks:{dependencies:false},capacity:"unknown"}
    end

    private
    def writable?(directory)
      Tempfile.create("openfly-readiness-",directory) { |file| file.write("probe"); file.flush; file.fsync }
      true
    rescue StandardError
      false
    end
  end
end
