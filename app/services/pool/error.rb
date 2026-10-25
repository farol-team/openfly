module Pool
  class Error < StandardError
    attr_reader :code, :status
    def initialize(code, status = 409, message = nil)
      @code, @status = code, status
      super(message || code.tr("_", " "))
    end
  end
end
