class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  before_create { self.id ||= "#{self.class.name.underscore}_#{SecureRandom.hex(12)}" if self.class.primary_key == "id" && self.class.columns_hash["id"].type == :string }
end
