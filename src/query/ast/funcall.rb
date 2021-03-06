module Query
  module AST
    class Funcall < Term
      attr_reader :name, :fn

      def initialize(name, *arguments)
        @name = name
        @fn = SQL_CONFIG.functions.function(name)
        unless @fn
          @fn = SQL_CONFIG.aggregate_functions.function(name) or
            raise "Unknown function: #{name}"
          @aggregate = true
        end
        @arguments = arguments
      end

      def dup
        self.class.new(@name.dup, *arguments.map(&:dup))
      end

      def display_value(raw_value, format=nil)
        self.type.display_value(raw_value, format || @fn.display_format)
      end

      def aggregate?
        @aggregate
      end

      def typecheck!
        @fn.typecheck!(arguments)
      rescue Sql::TypeError => e
        raise Sql::TypeError.new("#{self}: #{e}")
      end

      def convert_types!
        typecheck!
        self.arguments = @fn.coerce_argument_types(self.arguments)
      end

      def kind
        :funcall
      end

      def type
        @fn.return_type(self.arguments)
      end

      def to_s
        "#{@name}(" + arguments.map(&:to_s).join(',') + ")"
      end

      def to_sql
        @fn.expr.gsub(/%s/) { |m| self.first.to_sql }.gsub(/:(\d+)\b/) { |m|
          arguments[$1.to_i - 1].to_sql
        }
      end
    end
  end
end
