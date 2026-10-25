class AddSchedulingObservability < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants,:last_scheduled_at,:datetime
    add_column :operations,:output_first_seq,:bigint
    add_column :pool_sessions,:events_first_seq,:bigint
  end
end
