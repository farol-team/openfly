class AddFencingSequence < ActiveRecord::Migration[8.1]
  def up
    execute "CREATE SEQUENCE operation_fencing_epochs"
  end
  def down
    execute "DROP SEQUENCE operation_fencing_epochs"
  end
end
