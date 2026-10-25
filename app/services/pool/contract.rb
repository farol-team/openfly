module Pool
  module Contract
    SPEC = JSON.parse(File.read(Rails.root.join("api/openapi.json")))
    def self.validate!(schema, value)
      contract = {"$ref"=>"#/components/schemas/#{schema}", "components"=>SPEC.fetch("components")}
      raise Error.new("invalid_request",422) unless JSONSchemer.schema(contract).valid?(value)
      value
    end
  end
end
