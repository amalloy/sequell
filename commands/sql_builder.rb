#! /usr/bin/env ruby

require 'rubygems'
require 'treetop'
require 'commands/lg_node'
require 'commands/lg'
require 'commands/query_executors'
require 'commands/query_config'

module SQLBuilder
  include QueryConfig

  def self.query(params)
    query = SQLQuery.new(params)
    query_executor = QueryExecutors.create_executor(query)
    query_executor.execute
  rescue QueryError
    puts $!
  end

  class QueryError < Exception
    def initialize(message)
      @message = message
    end

    def to_s
      @message
    end
  end

  class QueryParseError < QueryError
    def initialize(cmdline, error_index)
      @cmdline = cmdline
      @error_index = error_index
      super.initialize("Malformed query at `#{cmdline[error_index .. -1]}`")
    end
  end

  # Represents a distinct SQL expression, which may be:
  # * Operator expression: <op> <expr> <expr> ...
  # * Atomic: <fieldname>, string, number.
  # * function call: fn(<expr>, <expr>, ...)
  class SQLExpr
    def self.create(query_node)
    end
  end

  class SQLQuery
    def initialize(config)
      @config = config
      @context = QueryConfig.context_by_name(config[:context])
      @cmdline = strip_command_identifier(config[:cmdline])
      @parser = ListgameQueryParser.new
      @query_ast = @parser.parse(@cmdline)
      if @query_ast.nil?
        raise QueryParseError.new(@cmdline, @parser.failure_index)
      end
      @query = QueryNode.resolve_node(@query_ast)

      validate_query
    end

    def to_s
      "Query[#{readable_query}]"
    end

    def readable_query
      @cmdline
    end

    def action_type
      @query.action_type
    end

    def action_flag
      @query.action_flag
    end

    def strip_command_identifier(command_line)
      command_line.sub(/^!\w+\s+/, '')
    end

    def validate_query
      # Check for common problems:
      assert(!@query.has_query_mode?) do
        "Query mode `#{@query.query_mode}` not permitted at top-level"
      end

      assert(!@query.has_multiple_result_indices?) do
        extra_indexes = @query.result_indices[1 .. -1].map { |e| e.text }
        "Too many result indexes in query (extras: #{extra_indexes.join(', ')})"
      end

      @query.subqueries.each do |subquery|
        assert(!subquery.action_type) do
          "Subquery #{subquery.text} has an action flag"
        end
      end
    end

    def assert(condition)
      if !condition
        err(yield)
      end
    end

    def err(message)
      raise QueryError.new(message)
    end

    def count_matching_records
      sql_db_handle.single_value(count_query, query_parameters)
    end

    def count_query
      "SELECT COUNT(*) #{query_sql}"
    end

    def select_query
      "SELECT #{query_select_fields.join(', ')} #{query_sql}"
    end

    def query_sql
      "#{from_clauses}#{where_clauses}#{group_by_clauses}#{having_clauses}"
    end

    def from_clauses
      query_table_list = query_tables.join(', ')
      " FROM " + query_table_list
    end

    def query_table_list
      [@context.table]
    end

    def where_clauses
    end

    def method_missing(symbol, *args, &block)
      @query.send(symbol, *args, &block)
    end

    def respond_to?(symbol)
      super.respond_to?(symbol) || @query.respond_to?(symbol)
    end
  end

  class QueryNode
    def self.resolve_elements(children)
      return [] if children.nil?
      results = []
      for c in children
        resolved = self.resolve_node(c)
        next if resolved.nil?
        if resolved.is_a?(Array)
          results += resolved
        else
          results << resolved
        end
      end
      results
    end

    def self.resolve_node(syntax_node)
      value =
        if syntax_node.lg_node
          QueryNode.new(syntax_node)
        else
          children = self.resolve_elements(syntax_node.elements)
          if children.size == 1
            children[0]
          else
            children
          end
        end
      if (value.is_a?(QueryNode) &&
          value.elements.size == 1 && value.elements[0].tag == value.tag &&
          value.elements[0].interval == value.interval) then
        return value.elements[0]
      end
      value
    end

    attr_reader :elements, :tag, :interval, :text

    def initialize(syntax_node)
      @tag = syntax_node.lg_node
      @elements = QueryNode.resolve_elements(syntax_node.elements)
      @text = syntax_node.text_value.strip
      @interval = syntax_node.interval
    end

    def has_query_mode?
      !!query_mode
    end

    ##
    # Returns the given query's query_mode (!lg/!lm) without looking at
    # subqueries.
    def query_mode
      node_text(node_tagged(:querymode, :exclude => :subquery))
    end

    def summary_query?
      !!my_node_tagged(:fieldgrouping)
    end

    def ratio_query?
      !!ratio_tail
    end

    def ratio_tail
      my_node_tagged(:queryratiotail)
    end

    def summary_grouped_fields
      summary_node = my_node_tagged(:fieldgrouping)
      if summary_node
        summary_node.nodes_tagged(:orderedfield).map { |f| f.text }
      else
        nil
      end
    end

    ##
    # If the query has an action flag (such as -tv, -log, -ttyrec), returns
    # the action string (viz. "tv", "log", or "ttyrec"), otherwise returns nil.
    def action_type
      node_text(node_tagged(:queryflagname))
    end

    def action_flag
      node_text(node_tagged(:queryflagbody))
    end

    def has_subqueries?
      subqueries.size > 0
    end

    def subqueries
      nodes_tagged(:subquery)
    end

    ##
    # Find all subqueries immediately under the current query, i.e. no
    # subsubqueries.

    def immediate_subqueries
      my_nodes_tagged(:subquery)
    end

    ##
    # Return all query keywords, such as DEFE, win, D:22

    def keywords
      my_nodes_tagged(:querykeywordexpr)
    end

    def nick_selector
      my_node_tagged(:nickselector)
    end

    def result_index
      node_text(my_node_tagged(:resultindex)) { |x| x.to_i }
    end

    def result_indices
      my_nodes_tagged(:resultindex)
    end

    def has_multiple_result_indices?
      result_indices.size > 1
    end

    ##
    # Returns a node's text, or nil if the node is nil
    def node_text(node)
      text_value = node ? node.text : nil
      if text_value && block_given?
        yield text_value
      else
        text_value
      end
    end

    ##
    # Returns the first node with the given tag in this query, i.e. not
    # in subqueries.

    def my_node_tagged(tag, options={})
      my_nodes_tagged(tag, options)[0]
    end

    ##
    # Returns all nodes with the given tag in this query, i.e. not in
    # subqueres.

    def my_nodes_tagged(tag, options={})
      options = options.dup
      options[:exclude_descent] = :subquery
      nodes_tagged(tag, options)
    end

    ##
    # Retrieves the first node with the given tag, searching recursively.

    def node_tagged(tag, options={})
      nodes_tagged(tag, options)[0]
    end

    ##
    # Retrieves all nodes with the given tag, searching recursively.

    def nodes_tagged(tag, options={})
      found_nodes = []
      @elements.each do |e|
        if node_included?(e, options) && !node_excluded?(e, options)
          found_nodes << e if e.tag == tag
          unless options[:exclude_match] || node_descent_excluded?(e, options)
            found_nodes += e.nodes_tagged(tag, options)
          end
        end
      end
      found_nodes
    end

    def node_included? (node, options)
      includes = options[:include]
      !includes || node.tag == includes ||
        (includes.respond_to?(:include?) && includes.include?(node.tag))
    end

    def node_excluded? (node, options)
      excludes = options[:exclude]
      node_matches_exclude?(node, excludes)
    end

    def node_descent_excluded? (node, options)
      excludes = options[:exclude_descent]
      node_matches_exclude?(node, excludes)
    end

    def node_matches_exclude? (node, excludes)
      excludes && (node.tag == excludes ||
                   (excludes.respond_to?(:include?) &&
                    excludes.include?(node.tag)))
    end

    def to_s
      "#{@tag} (#{@text})"
    end
  end
end
