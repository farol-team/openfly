module Pool
  class Maintenance
    def initialize(provider: Bridge.new)
      @provider = provider
      @last_retention = Time.at(0)
      @reconcilers = {}
    end

    def tick
      Scheduler.new.expire!
      if @last_retention < 1.minute.ago
        Retention.new.run
        ServiceHeartbeat.where("seen_at < ?", 1.day.ago).delete_all
        @last_retention = Time.current
      end
      # Provider calls must never block lease expiry. Each reservation is fenced
      # against both other reconcilers and the execution worker in PostgreSQL.
      @reconcilers.reject! { |_id,thread| !thread.alive? }
      available=4-@reconcilers.size
      return unless available.positive?

      work=Reconciler.due.where.not(id:@reconcilers.keys).limit(available).pluck(:id).map { |id| [id,:reconcile] }
      if work.size<available && @provider.respond_to?(:observe)
        work+=Observer.due.where.not(id:@reconcilers.keys).limit(available-work.size).pluck(:id).map { |id| [id,:observe] }
      end
      work.each do |id,action|
        @reconcilers[id] = Thread.new do
          Rails.application.executor.wrap do
            ApplicationRecord.connection_pool.with_connection do
              action==:reconcile ? Reconciler.new(provider: @provider).run_once(ids: [id]) : Observer.new(provider:@provider).run(id)
            end
          end
        rescue StandardError => error
          warn "OpenFly cleanup failed (#{error.class.name})"
        end
      end
    end

    def shutdown
      @reconcilers.each_value(&:join)
    end
  end
end
