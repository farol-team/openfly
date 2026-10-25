class CreateExecutionPool < ActiveRecord::Migration[8.1]
  def change
    create_table :tenants, id: :string do |t|
      t.string :name, null: false
      t.integer :max_vcpus, null: false, default: 4
      t.integer :max_memory_mib, null: false, default: 8192
      t.integer :max_queued, null: false, default: 20
      t.jsonb :template_ids, null: false, default: []
      t.timestamps
    end
    create_table :api_credentials, id: :string do |t|
      t.string :tenant_id, null: false
      t.string :digest, null: false
      t.jsonb :scopes, null: false, default: []
      t.datetime :revoked_at
      t.timestamps
    end
    add_foreign_key :api_credentials, :tenants
    add_index :api_credentials, :digest, unique: true
    create_table :runtime_templates, id: :string do |t|
      t.string :image_digest, null: false
      t.jsonb :resource_profiles, null: false, default: {}
      t.jsonb :network_profiles, null: false, default: {}
      t.jsonb :secret_slots, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    create_table :nodes, id: :string do |t|
      t.string :name, null: false
      t.string :provider, null: false
      t.string :state, null: false, default: "offline"
      t.integer :vcpus, null: false
      t.integer :memory_mib, null: false
      t.integer :disk_mib, null: false
      t.jsonb :config, null: false, default: {}
      t.datetime :checked_at
      t.timestamps
    end
    create_table :pool_sessions, id: :string do |t|
      t.string :tenant_id, null: false
      t.string :task_key, :task_version, :workspace_key, :template_id, :resource_profile, :network_profile, null: false
      t.string :state, null: false, default: "queued"
      t.integer :generation, :revision, null: false, default: 0
      t.integer :idle_timeout_seconds, null: false, default: 600
      t.datetime :expires_at, null: false
      t.string :cleanup_status, null: false, default: "none"
      t.string :last_accepted_checkpoint_id
      t.datetime :idle_since
      t.timestamps
    end
    add_index :pool_sessions, [:tenant_id, :id], unique: true
    add_index :pool_sessions, [:tenant_id,:task_key,:task_version], unique: true, where: "state NOT IN ('terminated','failed')", name: "unique_active_task_session"
    add_foreign_key :pool_sessions, :tenants
    add_foreign_key :pool_sessions, :runtime_templates, column: :template_id
    create_table :artifacts, id: :string do |t|
      t.string :tenant_id, null: false
      t.string :operation_id
      t.string :kind, :media_type, :sha256, null: false
      t.bigint :size_bytes, null: false
      t.string :state, null: false, default: "pending"
      t.boolean :recovery_only, null: false, default: false
      t.datetime :retention_expires_at
      t.timestamps
    end
    add_index :artifacts, [:tenant_id,:id], unique: true
    add_foreign_key :artifacts, :tenants
    create_table :operations, id: :string do |t|
      t.string :tenant_id, :session_id, :operation_key, :app_run_id, null: false
      t.string :input_artifact_id, :input_workspace_revision, :input_artifact_sha256, null: false
      t.string :request_artifact_id
      t.integer :expected_session_revision, null: false
      t.jsonb :argv, null: false
      t.string :cwd, null: false, default: "/workspace"
      t.string :permission_profile, null: false
      t.integer :timeout_seconds, null: false
      t.jsonb :secret_binding_ids, null: false, default: []
      t.string :state, null: false, default: "queued"
      t.string :execution_status, null: false, default: "not_started"
      t.string :checkpoint_status, null: false, default: "none"
      t.string :publication_eligibility, null: false, default: "pending"
      t.integer :generation, null: false, default: 0
      t.bigint :lease_epoch, null: false, default: 0
      t.string :runner_id, :reservation_id
      t.datetime :runner_seen_at, :started_at, :finished_at
      t.datetime :lease_expires_at, :deadline, :queue_deadline, null: false
      t.string :candidate_checkpoint_id, :result_artifact_id
      t.string :acknowledgement
      t.integer :acknowledged_revision
      t.datetime :acknowledged_at
      t.integer :exit_code
      t.string :error_code
      t.boolean :requires_reconciliation, :truncated, :redacted, :capture_complete, null: false, default: false
      t.bigint :output_bytes, null: false, default: 0
      t.timestamps
    end
    add_index :operations, [:tenant_id,:id], unique: true
    add_index :operations, [:session_id,:operation_key], unique: true
    add_index :operations, [:state,:created_at]
    add_index :operations, :session_id, unique: true, where: "acknowledgement IS NULL", name: "one_unacknowledged_operation"
    create_table :workspace_locks, id: :string do |t|
      t.string :tenant_id, :workspace_key, :operation_id, null: false
      t.timestamps
    end
    add_index :workspace_locks, [:tenant_id,:workspace_key], unique: true
    create_table :reservations, id: :string do |t|
      t.string :tenant_id, :session_id, :node_id, null: false
      t.string :state, null: false, default: "allocating"
      t.string :provider_id
      t.string :creation_key, null: false
      t.integer :vcpus, :memory_mib, :disk_mib, null: false
      t.datetime :released_at
      t.timestamps
    end
    add_index :reservations, :creation_key, unique: true
    add_index :reservations, :session_id, unique: true, where: "released_at IS NULL", name: "one_live_reservation"
    add_index :reservations, [:node_id,:released_at]
    add_foreign_key :reservations, :nodes
    create_table :secret_bindings, id: :string do |t|
      t.string :tenant_id, :session_id, :operation_key, :slot, null: false
      t.string :state, null: false, default: "available"
      t.datetime :expires_at, null: false
      t.string :consumed_by
      t.bigint :consumed_epoch
      t.timestamps
    end
    add_index :secret_bindings, [:tenant_id,:id], unique: true
    create_table :idempotency_records, id: :string do |t|
      t.string :tenant_id, :route, :key, :digest, :resource_type, :resource_id, null: false
      t.integer :status, null: false
      t.timestamps
    end
    add_foreign_key :idempotency_records, :tenants
    add_index :idempotency_records, [:tenant_id,:route,:key], unique: true, name: "unique_idempotency_key"
    create_table :pool_events do |t|
      t.string :tenant_id, :session_id, null: false
      t.string :operation_id
      t.string :event_type, null: false
      t.jsonb :details, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :pool_events, [:session_id,:id]
    create_table :output_chunks do |t|
      t.string :tenant_id, :operation_id, :stream, null: false
      t.text :text, null: false
      t.datetime :created_at, null: false
    end
    add_index :output_chunks, [:operation_id,:id]
    # Composite constraints prevent accidental cross-tenant references, even in trusted code.
    {operations: {session_id: :pool_sessions, input_artifact_id: :artifacts, request_artifact_id: :artifacts, candidate_checkpoint_id: :artifacts, result_artifact_id: :artifacts},
     artifacts: {operation_id: :operations}, pool_sessions: {last_accepted_checkpoint_id: :artifacts},
     workspace_locks: {operation_id: :operations}, reservations: {session_id: :pool_sessions},
     secret_bindings: {session_id: :pool_sessions}, pool_events: {session_id: :pool_sessions,operation_id: :operations},
     output_chunks: {operation_id: :operations}}.each do |table, links|
      links.each { |column, target| add_foreign_key table, target, column: [:tenant_id,column], primary_key: [:tenant_id,:id] }
    end
    add_check_constraint :operations, "execution_status IN ('not_started','started','unknown')", name: "execution_status_values"
    add_check_constraint :operations, "state IN ('queued','preparing','running','checkpointing','succeeded','failed','canceled','timed_out','interrupted','unknown')", name: "operation_state_values"
    add_check_constraint :pool_sessions, "state IN ('queued','allocating','ready','busy','parked','recovering','terminating','terminated','failed')", name: "session_state_values"
    add_check_constraint :artifacts, "size_bytes >= 0 AND size_bytes <= 268435456", name: "artifact_size_bounds"
  end
end
