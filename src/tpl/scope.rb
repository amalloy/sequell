# Hash-like object that provides the scope to evaluate a Sequell
# template AST (variable name -> value bindings).
module Tpl
  class BindingError < ::StandardError
    def initialize(key, val)
      @key = key
      @val = val
      super("Cannot rebind #{@key} to #{@val}")
    end
  end

  class Scope
    @@default_scope = nil
    def self.with_scope(scope)
      old_scope = @@default_scope
      @@default_scope = scope
      begin
        yield
      ensure
        @@default_scope = old_scope
      end
    end

    def self.default_scope
      @@default_scope
    end

    def self.wrap(scopelike={}, *delegates)
      if (scopelike.is_a?(self) &&
          (delegates.empty? || delegates[0] == scopelike))
        return scopelike
      end
      self.new(scopelike, *delegates) if self.mutable_scope?(scopelike)
      self.new({ }, scopelike, *delegates)
    end

    def self.block(&block)
      self.new({ }, block)
    end

    def self.mutable_scope?(scopelike)
      scopelike.respond_to?(:[]) && scopelike.respond_to?(:[]=) &&
        scopelike.respond_to?(:include?)
    end

    attr_reader :delegates
    def initialize(dict, *delegates)
      @dict = dict || { }
      @delegates = delegates.compact
    end

    def keys
      @dict.keys
    end

    def [](key)
      return @dict[key] if @dict.include?(key)
      delegate_lookup(key)
    end

    def []=(key, val)
      @dict[key] = val
    end

    def bound?(key)
      @dict.include?(key)
    end

    def rebind(key, val)
      if bound?(key)
        self[key] = val
      else
        delegates.each { |d|
          return d.rebind(key, val) if d.respond_to?(:rebind)
        }
        raise BindingError.new(key, val)
      end
    end

    def subscope(hash)
      Scope.wrap(hash, self)
    end

    def to_s
      "#{self.class}(#{@dict} // #{@delegates.size})"
    end

  protected
    def delegate_lookup(key)
      @delegates.each { |d|
        res = d[key]
        return res unless res.nil?
      }
      nil
    end
  end

  class LazyEvalScope < Scope
    def initialize(raw, scope)
      super({ }, scope)
      @raw = raw
      @scope = scope
    end

    def [](key)
      return @dict[key] if @dict.include?(key)
      if @raw.include?(key)
        @dict[key] ||= eval_tpl(@raw[key], @scope)
      else
        delegate_lookup(key)
      end
    end

    def eval_tpl(tpl, scope)
      return tpl.eval(scope) if tpl.respond_to?(:tpl?)
      tpl
    end

    def bound?(key)
      @raw.include?(key) || @dict.include?(key)
    end
  end
end
