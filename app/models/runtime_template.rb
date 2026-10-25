class RuntimeTemplate < ApplicationRecord
  validate :immutable_definition, on: :update
  private
  def immutable_definition
    if (%w[image_digest resource_profiles network_profiles secret_slots] & changed).any?
      errors.add(:base,"Create a new template ID to change an execution definition")
    end
  end
end
