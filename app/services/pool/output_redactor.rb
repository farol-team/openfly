module Pool
  # Stateful per-stream filtering. Incomplete lines stay private until another line
  # arrives; partial secret prefixes are never committed to the output table.
  class OutputRedactor
    def initialize(values)
      @secrets=values.flat_map { |value| expand(value) }.select { |value| value.is_a?(String) && !value.empty? }.uniq
      @pending=Hash.new { |h,k| h[k]=String.new }
    end
    attr_reader :secrets, :redacted
    def expand(value)
      case value
      when Hash then value.values.flat_map { |v| expand(v) }
      when Array then value.flat_map { |v| expand(v) }
      when String
        parsed=JSON.parse(value) rescue nil
        [value]+(parsed.is_a?(Hash) || parsed.is_a?(Array) ? expand(parsed) : [])
      else []
      end
    end
    def push(stream,text,final:false)
      buffer=@pending[stream]
      buffer<<text.to_s.encode('UTF-8',invalid: :replace,undef: :replace)
      cut=final ? buffer.length : (buffer.rindex("\n") || -1)+1
      unless final
        @secrets.each do |secret|
          # Hold a complete match straddling the proposed line boundary.
          start=0
          while (index=buffer.index(secret,start))
            cut=index if index<cut && index+secret.length>cut
            start=index+1
          end
          # Hold a suffix which might become a secret when the next chunk arrives.
          1.upto([secret.length-1,buffer.length].min) do |length|
            cut=[cut,buffer.length-length].min if buffer.end_with?(secret[0,length])
          end
        end
      end
      output=buffer.slice!(0,cut)
      original=output.dup
      @secrets.sort_by { |s| -s.length }.each { |secret| output=output.gsub(secret,'[REDACTED]') }
      output=output.gsub(/(Bearer\s+)[A-Za-z0-9._~+\/-]{16,}/i,'\1[REDACTED]').gsub(/((?:password|api_key|access_token)\s*[:=]\s*)[^\s]+/i,'\1[REDACTED]')
      @redacted ||= output!=original
      output
    end
  end
end
