class AddRuntimeObservability < ActiveRecord::Migration[8.1]
  def change
    create_table :service_heartbeats, id: :string do |t|
      t.string :role, null: false
      t.datetime :seen_at, null: false
      t.timestamps
    end
    add_index :service_heartbeats, [:role,:seen_at]
    add_column :reservations, :reconcile_attempts, :integer, null:false, default:0
    add_column :reservations, :next_reconcile_at, :datetime
    add_column :reservations, :last_error_code, :string
    add_column :reservations, :observed_state, :string, null:false, default:'unknown'
    add_column :reservations, :observed_at, :datetime
    add_column :operations, :wait_reason, :string
    add_column :operations, :request_id, :string
  end
end
