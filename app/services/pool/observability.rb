module Pool
  class Observability
    def call
      now=Time.current
      pending=Operation.where(acknowledgement:nil).where(state:%w[succeeded failed unknown canceled timed_out interrupted])
      quarantine=Reservation.where(released_at:nil,state:"quarantined")
      {readiness:Readiness.new.call,operations:Operation.group(:state).count,
       reservations:Reservation.where(released_at:nil).group(:state).count,
       pending_ack:pending.count,oldest_pending_ack_seconds:age(pending.minimum(:finished_at),now),
       oldest_queued_seconds:age(Operation.where(state:"queued").minimum(:created_at),now),
       quarantined_vcpus:quarantine.sum(:vcpus),quarantined_memory_mib:quarantine.sum(:memory_mib),
       artifact_bytes:Artifact.where(state:"ready").sum(:size_bytes),
       heartbeat_age_seconds:ServiceHeartbeat.group(:role).maximum(:seen_at).transform_values { |time| age(time,now) },
       nodes:Node.all.map { |node| node.attributes.slice(*%w[id name provider state checked_at]) }}
    end
    private
    def age(time,now) = time && [(now-time).round,0].max
  end
end
