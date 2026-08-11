# frozen_string_literal: true

require "json"
require "monitor"
require "set"
require_relative "contracts/version"

# Runtime behavioral contracts. Include in classes or extend for singleton contracts.
module Contracts
  SENSITIVE_NAMES = [/password/i, /token/i, /secret/i, /authorization/i, /api_key/i, /access_key/i, /credit_card/i,
                     /ssn/i].freeze

  class Error < StandardError
    def to_h = { error: self.class.name, message: message }
  end

  class DefinitionError < Error; end

  class Violation < Error
    attr_reader :owner, :method_name, :contract_type, :description, :expected, :actual, :parameter, :context,
                :source_location, :original_exception

    def initialize(message = nil, owner: nil, method_name: nil, contract_type: nil, description: nil, expected: nil,
                   actual: nil, parameter: nil, context: nil, source_location: nil, original_exception: nil)
      @owner = owner
      @method_name = method_name
      @contract_type = contract_type
      @description = description
      @expected = expected
      @actual = actual
      @parameter = parameter
      @context = context
      @source_location = source_location
      @original_exception = original_exception
      super(message || "#{owner}##{method_name} violated #{contract_type}: #{description || expected}")
    end
  end
  %i[Parameter Precondition Postcondition Return Invariant Mutation UnexpectedException Inheritance].each do |name|
    const_set("#{name}Violation", Class.new(Violation))
  end
  class SnapshotError < Error
    attr_reader :strategy, :field, :receiver_class, :original_exception

    def initialize(message = nil, strategy: nil, field: nil, receiver_class: nil, original_exception: nil)
      @strategy = strategy
      @field = field
      @receiver_class = receiver_class
      @original_exception = original_exception
      super(message)
    end
  end

  class StateObservationError < SnapshotError; end

  class CompositeViolation < Violation
    attr_reader :violations

    def initialize(violations:, original_exception: nil)
      @violations = violations.freeze
      super("multiple contract violations: #{violations.map(&:message).join('; ')}", original_exception: original_exception)
    end

    def primary_violation = violations.first
  end

  class Configuration
    attr_accessor :enabled, :failure_mode, :sample_rate, :logger, :include_values_in_errors, :capture_source_locations,
                  :undeclared_exceptions, :invariant_checking, :inheritance_mode, :snapshot_strategy, :sampler, :redacted_parameters, :redactor, :check_invariant_after_exception, :check_invariants_after_initialize, :snapshot_provider, :allow_private_state_readers, :unsupported_deep_copy, :state_equality, :verify_state_after_exception, :allow_invariant_suppression

    def initialize
      @enabled = true
      @failure_mode = :raise
      @sample_rate = 1.0
      @logger = nil
      @include_values_in_errors = false
      @capture_source_locations = true
      @undeclared_exceptions = :ignore
      @invariant_checking = :contracted_methods
      @inheritance_mode = :merge

      @snapshot_strategy = :declared
      @sampler = nil
      @redacted_parameters = SENSITIVE_NAMES.dup
      @redactor = nil
      @check_invariant_after_exception = false
      @check_invariants_after_initialize = true

      @snapshot_provider = nil
      @allow_private_state_readers = true
      @unsupported_deep_copy = :reference
      @state_equality = :eql
      @verify_state_after_exception = false
      @allow_invariant_suppression = false
    end

    def profile(_name, &) = Profile.new(self).instance_eval(&)

    class Profile
      def initialize(config) = @config = config
      def method_missing(name, value = nil) = @config.public_send("#{name}=", value)

      def respond_to_missing?(name, include_private = false)
        @config.respond_to?("#{name}=", include_private) || super
      end
    end
  end

  class Context
    attr_accessor :result, :exception, :finished_at, :before
    attr_reader :receiver, :owner, :method_name, :arguments, :keyword_arguments, :block_given, :started_at,
                :source_location, :contract, :parent, :depth, :trace_id

    def initialize(receiver:, contract:, arguments:, keyword_arguments:, block_given:, parent: nil)
      @receiver = receiver
      @contract = contract
      @owner = contract.owner
      @method_name = contract.method_name
      @arguments = arguments.freeze
      @keyword_arguments = keyword_arguments.freeze
      @block_given = block_given
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @source_location = contract.source_location
      @parent = parent
      @depth = parent ? parent.depth + 1 : 0
      @trace_id = parent ? parent.trace_id : "c#{object_id.to_s(36)}"
    end

    def duration = @finished_at && (@finished_at - @started_at)
  end

  class Snapshot
    attr_reader :metadata

    def initialize(values, metadata: {})
      @values = values.transform_keys(&:to_sym).freeze
      @metadata = metadata.freeze
      freeze
    end

    def [](key) = @values[key.to_sym]
    # Explicit splat parameters keep this compatible with Ruby 3.1.
    def fetch(key, *arguments) = @values.fetch(key.to_sym, *arguments)
    def to_h = @values.dup
    def key?(key) = @values.key?(key.to_sym)
    def keys = @values.keys
    def values = @values.values
    def dig(*arguments) = @values.dig(*arguments)
    def method_missing(name, *arguments) = @values.fetch(name) { super }
    def respond_to_missing?(name, include_private = false) = @values.key?(name) || super
  end

  class ExecutionGuard
    def self.stack
      stores = Thread.current[:contracts_execution_guard] ||= {}
      stores[Fiber.current] ||= []
    end

    def self.active?(key) = stack.include?(key)
    def self.depth = stack.length
    def self.current_stack = stack.dup.freeze

    def self.enter(key)
      return yield(false) if active?(key)

      stack << key
      yield(true)
    ensure
      stack.pop if stack.last == key
    end
  end

  Observation = Struct.new(:name, :reader, :deep, :compare_with, keyword_init: true) do
    def to_h = { name: name, deep: deep, comparator: compare_with }
  end
  Invariant = Struct.new(:id, :owner, :description, :predicate, :source_location, :options, :inherited_from,
                         keyword_init: true)
  class MutationReport
    attr_reader :changed_fields, :unchanged_fields, :permitted_changes, :unexpected_changes, :missing_required_changes,
                :before_values, :after_values

    def initialize(before:, after:, permitted:, required:, observations:)
      @before_values = before.to_h.freeze
      @after_values = after.to_h.freeze
      @permitted_changes = permitted.freeze
      fields = @before_values.keys | @after_values.keys
      @changed_fields = fields.reject do |field|
        Contracts.equal_state?(@before_values[field], @after_values[field], observations[field]&.compare_with)
      end.freeze
      @unchanged_fields = (fields - @changed_fields).freeze
      @unexpected_changes = (@changed_fields - permitted).freeze
      @missing_required_changes = (required - @changed_fields).freeze
    end

    def passed? = unexpected_changes.empty? && missing_required_changes.empty?

    def to_h
      { passed: passed?, changed_fields: changed_fields, unchanged_fields: unchanged_fields,
        permitted_changes: permitted_changes, unexpected_changes: unexpected_changes, missing_required_changes: missing_required_changes, before_values: before_values, after_values: after_values }
    end
  end

  module Constraints
    class Base
      def to_h = { type: self.class.name.split("::").last.downcase, description: description }
    end

    class Type < Base
      def initialize(type) = @type = type
      def matches?(value) = value.is_a?(@type)
      def description = @type.is_a?(Module) ? @type.name : @type.to_s
    end

    class Union < Base
      def initialize(*items) = @items = items.map { |item| Constraints.coerce(item) }
      def matches?(value) = @items.any? { |item| item.matches?(value) }
      def description = @items.map(&:description).join(" or ")
    end

    class Nilable < Union
      def initialize(item) = super(NilClass, item)
    end

    class Predicate < Base
      def initialize(description, &block)
        (@description = description
         @block = block)
      end

      def matches?(value) = @block.call(value)
      attr_reader :description
    end

    class Regex < Base
      def initialize(regex) = @regex = regex
      def matches?(value) = value.is_a?(String) && @regex.match?(value)
      def description = "matching #{@regex.inspect}"
    end

    class Range < Base
      def initialize(range) = @range = range
      def matches?(value) = @range.cover?(value)
      def description = "in #{@range.inspect}"
    end

    class OneOf < Base
      def initialize(*values) = @values = values.freeze
      def matches?(value) = @values.include?(value)
      def description = "one of #{@values.inspect}"
    end

    class ArrayOf < Base
      def initialize(item) = @item = Constraints.coerce(item)
      def matches?(value) = value.is_a?(Array) && value.all? { |v| @item.matches?(v) }
      def description = "Array<#{@item.description}>"
    end

    class HashOf < Base
      def initialize(key, value)
        (@key = Constraints.coerce(key)
         @value = Constraints.coerce(value))
      end

      def matches?(value) = value.is_a?(Hash) && value.all? { |k, v| @key.matches?(k) && @value.matches?(v) }
      def description = "Hash<#{@key.description}, #{@value.description}>"
    end

    class RespondTo < Base
      def initialize(*methods) = @methods = methods
      def matches?(value) = @methods.all? { |method| value.respond_to?(method) }
      def description = "responding to #{@methods.join(', ')}"
    end

    class DuckType < RespondTo; end

    class Anything < Base
      def matches?(_) = true
      def description = "anything"
    end

    class Nothing < Base
      def matches?(_) = false
      def description = "nothing"
    end

    module_function

    def coerce(value) = value.respond_to?(:matches?) && value.respond_to?(:description) ? value : Type.new(value)
  end

  Condition = Struct.new(:description, :block, keyword_init: true)
  ExceptionRule = Struct.new(:type, :condition, :handler, keyword_init: true)
  class Contract
    attr_accessor :method_source_location
    attr_reader :id, :owner, :method_name, :method_type, :parameters, :positionals, :preconditions, :postconditions,
                :return_constraint, :invariants, :allowed_exceptions, :mutation_policy, :observed, :snapshot_block, :source_location, :options, :examples, :required_changes, :unchanged_on_raise_types

    def initialize(owner:, method_name:, source_location:, method_type: :instance, options: {})
      @id = "#{owner.name || owner.object_id}:#{method_type}:#{method_name}".freeze

      @owner = owner
      @method_name = method_name.to_sym
      @method_type = method_type
      @source_location = source_location
      @options = options.freeze
      @parameters = {}

      @positionals = []
      @preconditions = []
      @postconditions = []
      @allowed_exceptions = []
      @invariants = []
      @observed = []
      @examples = []
      @required_changes = []
      @unchanged_on_raise_types = []
      @mutation_policy = :unspecified
    end

    def parameters=(value)
      @parameters = value.transform_keys(&:to_sym).transform_values { |v| Constraints.coerce(v) }.freeze
    end

    def positionals=(value)
      @positionals = value.map { |v| Constraints.coerce(v) }.freeze
    end

    def return_constraint=(value)
      @return_constraint = value && Constraints.coerce(value)
    end

    def to_h
      { id: id, owner: owner.name, method_name: method_name, method_type: method_type, parameters: parameters.transform_values(&:description), positional: positionals.map(&:description), preconditions: preconditions.map(&:description), postconditions: postconditions.map(&:description), return_constraint: return_constraint&.description, invariants: Contracts.invariants_for(owner).map(&:description), allowed_exceptions: allowed_exceptions.map do |r|
        r.type.name
      end, mutation_policy: mutation_policy, observed: observed.map(&:to_h), permitted_changes: permitted_changes, required_changes: required_changes, source_location: source_location, method_source_location: method_source_location, options: options }
    end

    def to_json(*) = JSON.generate(to_h)
    def observed_fields = observed.map(&:name).freeze
    def permitted_changes = mutation_policy == :pure ? [] : (@permitted_changes || []).freeze
    def pure? = mutation_policy == :pure
    def all_invariants = Contracts.invariants_for(owner)
    def own_invariants = Contracts.invariants_for(owner).select { |invariant| invariant.owner == owner }
    def inherited_invariants = all_invariants - own_invariants

    def permitted_changes=(values)
      @permitted_changes = values.map(&:to_sym).freeze
    end

    def required_change_bounds
      @required_change_bounds || {}.freeze
    end
  end

  class ContractBuilder
    def initialize(contract) = @contract = contract
    def params(**items) = @contract.parameters = items
    def positional(*items) = @contract.positionals = items
    def requires(description = "precondition", &block) = add(@contract.preconditions, description, block)
    def ensures(description = "postcondition", &block) = add(@contract.postconditions, description, block)
    def returns(constraint) = @contract.return_constraint = constraint
    def returns!(constraint) = @contract.return_constraint = Constraints::Predicate.new("non-nil #{Constraints.coerce(constraint).description}") { |v| !v.nil? && Constraints.coerce(constraint).matches?(v) }

    def raises(*types, &block)
      types.each do |type|
        @contract.allowed_exceptions << ExceptionRule.new(type: type, condition: block)
      end
    end

    def on_raise(type, &block) = @contract.allowed_exceptions << ExceptionRule.new(type: type, handler: block)

    def changes(*attributes)
      validate_mutation_mode!(:changes)
      observe(*attributes.reject do |attribute|
        @contract.observed.any? do |item|
          item.name == attribute.to_sym
        end
      end)
      @contract.instance_variable_set(:@mutation_policy, :changes)
      @contract.permitted_changes = attributes
    end

    def observe(*attributes, deep: false, compare_with: nil, &reader)
      attributes.each do |attribute|
        existing = @contract.observed.find { |item| item.name == attribute.to_sym }
        raise DefinitionError, "duplicate observation for #{attribute}" if existing

        @contract.observed << Observation.new(name: attribute.to_sym, reader: reader, deep: deep,
                                              compare_with: compare_with)
      end
    end

    def must_change(*attributes, from: nil, to: nil)
      validate_mutation_mode!(:must_change)
      bounds = @contract.instance_variable_get(:@required_change_bounds) || {}
      attributes.each do |attribute|
        bounds[attribute.to_sym] = { from: from, to: to }.freeze
      end
      @contract.instance_variable_set(:@required_change_bounds, bounds.freeze)
      observe(*attributes.reject do |attribute|
        @contract.observed.any? do |item|
          item.name == attribute.to_sym
        end
      end)
      @contract.required_changes.concat(attributes.map(&:to_sym)).uniq!
    end

    def pure(scope: :receiver)
      raise DefinitionError, "unsupported purity scope #{scope.inspect}" unless %i[receiver observed].include?(scope)

      validate_mutation_mode!(:pure)
      @contract.instance_variable_set(:@mutation_policy, :pure)
    end
    alias changes_nothing pure
    def snapshot(&block) = @contract.instance_variable_set(:@snapshot_block, block)
    def unchanged_on_raise(*types) = @contract.unchanged_on_raise_types.concat(types.empty? ? [StandardError] : types).uniq!
    def example(**value) = @contract.examples << value.freeze

    private

    def add(collection, description, block)
      raise DefinitionError, "a contract condition needs a block" unless block

      collection << Condition.new(description: description, block: block)
    end

    def validate_mutation_mode!(mode)
      current = @contract.mutation_policy
      return unless current != :unspecified && current != mode && !(current == :changes && mode == :must_change)

      raise DefinitionError,
            "#{mode} conflicts with #{current}"
    end
  end

  class Registry
    def initialize
      (@lock = Monitor.new
       @contracts = {})
    end

    def register(contract)
      @lock.synchronize do
        @contracts[[contract.owner, contract.method_type, contract.method_name]] = contract
      end
    end

    def find(owner, method_name, method_type: :instance)
      @lock.synchronize do
        @contracts[[owner, method_type, method_name.to_sym]] || inherited(owner, method_name, method_type)
      end
    end

    def for_class(owner) = @lock.synchronize { @contracts.values.select { |c| c.owner == owner }.dup.freeze }
    def all = @lock.synchronize { @contracts.values.dup.freeze }
    private

    def inherited(owner, method_name, type)
      return nil if Contracts.configuration.inheritance_mode == :independent

      owner.ancestors.drop(1).filter_map { |ancestor| @contracts[[ancestor, type, method_name.to_sym]] }.first
    end
  end

  class << self
    def configuration = @configuration ||= Configuration.new
    def configure = yield(configuration)
    def registry = @registry ||= Registry.new

    def contract_for(owner, method_name,
                     method_type: :instance)
      registry.find(owner, method_name, method_type: method_type)
    end

    def invariants_for(owner)
      owner.ancestors.flat_map do |ancestor|
        registry.for_class(ancestor).flat_map(&:invariants)
      end.freeze
    end

    def check_invariants(object)
      invariants_for(object.class).map do |invariant|
        { passed: !!object.instance_exec(&invariant.predicate), type: :invariant, description: invariant.description,
          invariant_id: invariant.id }.freeze
      end.freeze
    rescue StandardError => e
      [{ passed: false, type: :invariant, description: e.message, error: e }.freeze].freeze
    end

    def check_invariants!(object)
      failed = check_invariants(object).find { |result| !result[:passed] }
      if failed
        raise InvariantViolation.new(owner: object.class, method_name: :__invariant__, contract_type: :invariant,
                                     description: failed[:description])
      end

      true
    end

    def register_comparator(name, &block) = (comparators[name.to_sym] = block)
    def comparators = (@comparators ||= {})

    def equal_state?(before, after, comparator = nil)
      comparator = comparators[comparator] if comparator.is_a?(Symbol)
      return comparator.call(before, after) if comparator.respond_to?(:call)

      if configuration.state_equality == :identity
        before.equal?(after)
      else
        configuration.state_equality == :equal ? before == after : before.eql?(after)
      end
    end

    def describe(owner, method_name = nil)
      contracts = method_name ? [contract_for(owner, method_name)].compact : registry.for_class(owner)
      contracts.map(&:to_h)
    end

    def any(*items) = Constraints::Union.new(*items)
    def nilable(item) = Constraints::Nilable.new(item)
    def matching(regex) = Constraints::Regex.new(regex)
    def range(value) = Constraints::Range.new(value)
    def one_of(*values) = Constraints::OneOf.new(*values)
    def array_of(item) = Constraints::ArrayOf.new(item)
    def hash_of(key, value) = Constraints::HashOf.new(key, value)
    def predicate(description, &) = Constraints::Predicate.new(description, &)
    def respond_to(*methods) = Constraints::RespondTo.new(*methods)
    def duck_type(*methods) = Constraints::DuckType.new(*methods)
    def anything = Constraints::Anything.new
    def nothing = Constraints::Nothing.new

    def invoke(receiver, contract, args, kwargs, block)
      return yield unless active?(contract, receiver, args, kwargs)

      parent = Thread.current[:contracts_context]

      context = Context.new(receiver: receiver, contract: contract, arguments: args, keyword_arguments: kwargs,
                            block_given: !block.nil?, parent: parent)
      Thread.current[:contracts_context] = context
      validate_parameters(contract, context)

      check_contract_invariants(receiver, contract, context, :before)
      context.before = capture(receiver, contract)
      check_conditions(contract.preconditions, context, :precondition)
      begin
        context.result = yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        context.exception = e
        if configuration.verify_state_after_exception || !contract.unchanged_on_raise_types.empty?
          after = capture(receiver, contract)
          report = MutationReport.new(before: context.before, after: after, permitted: [], required: [], observations: contract.observed.to_h do |o|
            [o.name, o]
          end)
          if !contract.unchanged_on_raise_types.empty? && contract.unchanged_on_raise_types.any? do |type|
            e.is_a?(type)
          end && !report.changed_fields.empty?
            fail!(MutationViolation, context,
                  description: "state changed after exception: #{report.changed_fields.join(', ')}", actual: report.to_h, original_exception: e)
          end
          check_contract_invariants(receiver, contract, context, :after_exception)
        end
        handle_exception(contract, context)

        check_contract_invariants(receiver, contract, context, :after) if configuration.check_invariant_after_exception
        raise
      else
        validate_return(contract, context)

        check_conditions(contract.postconditions, context, :postcondition)
        validate_mutation(contract, context)
        check_contract_invariants(receiver, contract, context, :after)
        context.result
      ensure
        context.finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        Thread.current[:contracts_context] = parent
      end
    end

    def active?(contract, receiver, args, kwargs)
      return false unless configuration.enabled
      if configuration.sampler
        return configuration.sampler.call(Context.new(receiver: receiver, contract: contract, arguments: args,
                                                      keyword_arguments: kwargs, block_given: false))
      end

      rate = contract.options.fetch(:sample_rate, configuration.sample_rate)
      rate >= 1 || (rate.positive? && rand < rate)
    end

    def fail!(klass, context, description:, expected: nil, actual: nil, parameter: nil, original_exception: nil)
      error = klass.new(owner: context.owner, method_name: context.method_name,
                        contract_type: klass.name.split("::").last.sub("Violation", "").downcase, description: description, expected: expected, actual: actual, parameter: parameter, context: context, source_location: context.source_location, original_exception: original_exception)
      instrument_violation(error)
      case configuration.failure_mode
      when :raise then raise error
      when :warn then warn error.message
      when :log then configuration.logger&.error(error.message)
      when :collect then (Thread.current[:contracts_violations] ||= []) << error
      else raise DefinitionError, "unknown failure_mode #{configuration.failure_mode.inspect}"
      end
      error
    end

    def instrument_violation(error)
      return unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.instrument(
        "contracts.violation",
        owner: error.owner,
        method_name: error.method_name,
        contract_type: error.contract_type,
        description: error.description,
        duration: error.context&.duration,
        source_location: error.source_location
      )
    end

    private

    def validate_parameters(contract, context)
      contract.positionals.each_with_index do |constraint, index|
        validate_constraint(constraint, context.arguments[index], context, "argument #{index}", index)
      end
      contract.parameters.each do |name, constraint|
        validate_constraint(constraint, context.keyword_arguments[name], context, name, name)
      end
    end

    def validate_constraint(constraint, value, context, label, parameter)
      return if constraint.matches?(value)

      actual = configuration.include_values_in_errors ? redact(parameter, value) : value.class.name
      fail!(ParameterViolation, context, description: "#{label} does not satisfy #{constraint.description}",
                                         expected: constraint.description, actual: actual, parameter: parameter)
    end

    def validate_return(contract, context)
      return unless contract.return_constraint && !contract.return_constraint.matches?(context.result)

      fail!(ReturnViolation, context,
            description: "return value does not satisfy #{contract.return_constraint.description}", expected: contract.return_constraint.description, actual: context.result.class.name)
    end

    def check_conditions(conditions, context, kind)
      conditions.each do |condition|
        result = call_condition(condition.block, context)
        unless result
          fail!(kind == :precondition ? PreconditionViolation : PostconditionViolation, context,
                description: condition.description)
        end
      end
    end

    def call_condition(block, context)
      params = block.parameters
      return context.receiver.instance_exec(context: context, &block) if params.any? { |(_, name)| name == :context }

      accepted_keys = params.filter_map { |kind, name| name if %i[key keyreq keyrest].include?(kind) }
      accepts_all_keys = params.any? { |kind, _| kind == :keyrest }
      available = context.keyword_arguments.merge(before: context.before)
      kwargs = accepts_all_keys ? available : available.slice(*accepted_keys)
      if params.empty? then context.receiver.instance_exec(&block)
      elsif params.first&.last == :result then context.receiver.instance_exec(context.result, **kwargs, &block)
      elsif context.result && params.any? do |(_, name)|
        name == :before
      end then context.receiver.instance_exec(context.result, **kwargs, &block)
      elsif context.result && params.length == 1 && params.first.first != :keyreq then context.receiver.instance_exec(
        context.result, &block
      )
      else context.receiver.instance_exec(*context.arguments, **kwargs, &block)
      end
    end

    def capture(receiver, contract)
      strategy = configuration.snapshot_strategy
      return Snapshot.new({}, metadata: snapshot_metadata(receiver, contract, strategy, [])) if strategy == :none

      data = if contract.snapshot_block then receiver.instance_exec(&contract.snapshot_block)
             elsif configuration.snapshot_provider then configuration.snapshot_provider.call(receiver, contract, nil)
             else
               observations = contract.observed
               if observations.empty? && strategy == :instance_variables
                 observations = receiver.instance_variables.map do |value|
                   Observation.new(name: value.to_s.delete_prefix("@").to_sym,
                                   deep: false)
                 end
               end
               observations.to_h { |observation| [observation.name, read_observation(receiver, observation)] }
             end
      unless data.respond_to?(:to_h)
        raise SnapshotError.new("snapshot provider must return a Hash", strategy: strategy,
                                                                        receiver_class: receiver.class)
      end

      values = data.to_h.transform_keys(&:to_sym)
      contract.observed.each do |observation|
        if (observation.deep || contract.pure?) && values.key?(observation.name)
          values[observation.name] =
            deep_copy(values[observation.name])
        end
      end
      Snapshot.new(values, metadata: snapshot_metadata(receiver, contract, strategy, contract.observed))
    rescue SnapshotError
      raise
    rescue StandardError => e
      raise SnapshotError.new("could not capture snapshot: #{e.message}", strategy: strategy,
                                                                          receiver_class: receiver.class, original_exception: e)
    end

    def copy(value)
      immutable = value.nil? || value.is_a?(Numeric) || value.is_a?(Symbol) || value == true || value == false || value.frozen?
      immutable ? value : value.dup.freeze
    rescue TypeError
      value
    end

    def deep_copy(value)
      case value
      when Hash then value.transform_values { |item| deep_copy(item) }.freeze
      when Array then value.map { |item| deep_copy(item) }.freeze
      when Set then value.to_set { |item| deep_copy(item) }.freeze
      when String then value.dup.freeze
      when Numeric, Symbol, TrueClass, FalseClass, NilClass then value
      else
        return value if configuration.unsupported_deep_copy == :reference
        if configuration.unsupported_deep_copy == :error
          raise SnapshotError,
                "unsupported deep snapshot value #{value.class}"
        end

        copy(value)
      end
    end

    def read_observation(receiver, observation)
      return receiver.instance_exec(receiver, &observation.reader) if observation.reader
      return receiver.public_send(observation.name) if receiver.respond_to?(observation.name)
      return receiver.send(observation.name) if configuration.allow_private_state_readers && receiver.respond_to?(
        observation.name, true
      )

      variable = "@#{observation.name}"
      return receiver.instance_variable_get(variable) if receiver.instance_variable_defined?(variable)

      raise StateObservationError.new("cannot observe #{observation.name}", field: observation.name,
                                                                            receiver_class: receiver.class)
    end

    def snapshot_metadata(receiver, contract, strategy, observations)
      { receiver_class: receiver.class.name, receiver_object_id: receiver.object_id, captured_at: Time.now,
        strategy: strategy, observed_fields: observations.map(&:name).freeze, deep_fields: observations.select(&:deep).map(&:name).freeze, contract_id: contract.id }
    end

    def validate_mutation(contract, context)
      return if contract.mutation_policy == :unspecified

      after = capture(context.receiver, contract)
      permitted = contract.mutation_policy == :pure ? [] : contract.permitted_changes
      report = MutationReport.new(before: context.before, after: after, permitted: permitted, required: contract.required_changes, observations: contract.observed.to_h do |item|
        [item.name, item]
      end)
      bounds_violations = required_change_bound_violations(contract, context.before, after, report)
      return if report.passed? && bounds_violations.empty?

      parts = []
      unless report.passed?
        parts << "unexpected changes: #{report.unexpected_changes.join(', ')}; missing changes: #{report.missing_required_changes.join(', ')}"
      end
      parts.concat(bounds_violations)
      fail!(MutationViolation, context,
            description: parts.join("; "), expected: permitted, actual: report.to_h)
    end

    def required_change_bound_violations(contract, before, after, report)
      contract.required_change_bounds.each_with_object([]) do |(field, bounds), violations|
        next unless report.changed_fields.include?(field)

        from = bounds[:from]
        to = bounds[:to]
        if from && !bound_value_matches?(before[field], from)
          violations << "#{field} must change from #{bound_description(from)} (was #{bound_value_label(before[field])})"
        end
        if to && !bound_value_matches?(after[field], to)
          violations << "#{field} must change to #{bound_description(to)} (got #{bound_value_label(after[field])})"
        end
      end
    end

    def bound_value_matches?(value, bound)
      case bound
      when Array then bound.any? { |item| equal_state?(value, item) }
      else equal_state?(value, bound)
      end
    end

    def bound_description(bound)
      bound.is_a?(Array) ? bound.inspect : bound.inspect
    end

    def bound_value_label(value)
      value.is_a?(Symbol) ? value.inspect : value.inspect
    end

    def check_contract_invariants(receiver, _contract, context, _phase)
      return unless configuration.invariant_checking == :contracted_methods

      invariants = invariants_for(receiver.class)
      return if invariants.empty?

      key = [receiver.object_id, :invariant]
      ExecutionGuard.enter(key) do |entered|
        if entered
          check_conditions(invariants.map do |item|
            Condition.new(description: item.description, block: item.predicate)
          end, context, :invariant)
        end
      end
    end

    def handle_exception(contract, context)
      matches = contract.allowed_exceptions.select do |rule|
        context.exception.is_a?(rule.type) && (!rule.condition || call_condition(rule.condition, context))
      end
      matches.each do |rule|
        next unless rule.handler

        passed = call_exception_condition(rule.handler, context)
        unless passed
          fail!(PostconditionViolation, context, description: "exception postcondition for #{rule.type} failed",
                                                 original_exception: context.exception)
        end
      end
      return unless matches.empty?

      case configuration.undeclared_exceptions
      when :violate then fail!(UnexpectedExceptionViolation, context,
                               description: "undeclared exception #{context.exception.class}", original_exception: context.exception)
      when :warn then configuration.logger ? configuration.logger.warn("undeclared exception #{context.exception.class} in #{context.owner}##{context.method_name}") : warn("undeclared exception #{context.exception.class} in #{context.owner}##{context.method_name}")
      end
    end

    def call_exception_condition(block, context)
      params = block.parameters
      return context.receiver.instance_exec(context: context, &block) if params.any? { |_, name| name == :context }

      kwargs = context.keyword_arguments.merge(before: context.before)
      accepted = params.filter_map { |kind, name| name if %i[key keyreq keyrest].include?(kind) }
      kwargs = kwargs.slice(*accepted) unless params.any? { |kind, _| kind == :keyrest }
      context.receiver.instance_exec(context.exception, **kwargs, &block)
    end

    def redact(name, value)
      return configuration.redactor.call(name, value) if configuration.redactor
      return "[REDACTED]" if configuration.redacted_parameters.any? { |pattern| pattern.match?(name.to_s) }

      value.inspect
    end
  end

  def self.included(base)
    base.extend(ClassMethods)
    base.include(InstanceMethods)
  end

  def self.extended(base) = base.extend(SingletonClassMethods)

  module ClassMethods
    def contract(name = nil, **options, &block)
      if name.nil? then @__contracts_pending = [options, block, caller_locations(1, 1).first]
                        return
      end
      declare_contract(name, :instance, options, &block)
    end

    def invariant(description = "invariant", &block)
      location = caller_locations(1, 1).first
      contract = Contracts.registry.find(self,
                                         :__invariant__) || Contract.new(owner: self, method_name: :__invariant__,
                                                                         source_location: location)
      contract.invariants << Invariant.new(id: "#{name || object_id}:#{caller_locations(1, 1).first.lineno}",
                                           owner: self, description: description, predicate: block, source_location: caller_locations(1, 1).first, options: {})

      Contracts.registry.register(contract)
      @__contracts_has_invariants = true
      wrap_initialize_for_invariants if method_defined?(:initialize,
                                                        false) || private_method_defined?(:initialize, false)
    end

    def snapshot(&block) = (@__contracts_snapshot = block)

    def method_added(name)
      return if @__contracts_hook

      if (pending = @__contracts_pending)
        @__contracts_pending = nil

        declare_contract(name, :instance, pending[0], source_location: pending[2], &pending[1])
      elsif (contract = Contracts.registry.find(self, name, method_type: :instance)) && contract.owner == self
        wrap_contract(name, contract)
      elsif (contract = Contracts.registry.find(self, name, method_type: :singleton)) && contract.owner == self
        wrap_contract(name, contract)
      end
      wrap_initialize_for_invariants if name == :initialize && @__contracts_has_invariants
      super
    end

    def declare_contract(name, type, options, source_location: caller_locations(2, 1).first, &block)
      contract = Contract.new(owner: self, method_name: name, method_type: type, source_location: source_location,
                              options: options)
      ContractBuilder.new(contract).instance_eval(&block) if block
      merge_parent_contract!(contract) unless Contracts.configuration.inheritance_mode == :independent
      if contract.snapshot_block.nil? && @__contracts_snapshot
        contract.instance_variable_set(:@snapshot_block,
                                       @__contracts_snapshot)
      end
      Contracts.registry.register(contract)

      wrap_contract(name, contract) if method_defined?(name,
                                                       false) || private_method_defined?(name,
                                                                                         false) || protected_method_defined?(
                                                                                           name, false
                                                                                         )
      contract
    end

    def merge_parent_contract!(contract)
      parent = ancestors.drop(1).lazy.map do |ancestor|
        Contracts.registry.for_class(ancestor).find do |candidate|
          candidate.method_name == contract.method_name && candidate.method_type == contract.method_type
        end
      end.find(&:itself)
      return unless parent

      if Contracts.configuration.inheritance_mode == :strict
        parent.parameters.each do |name, constraint|
          child = contract.parameters[name]
          if child && child.description != constraint.description
            raise InheritanceViolation.new(owner: self, method_name: contract.method_name, contract_type: :inheritance,
                                           description: "parameter #{name} changes parent constraint #{constraint.description}")
          end
        end
      end
      contract.parameters = parent.parameters.merge(contract.parameters) unless parent.parameters.empty?
      contract.positionals = parent.positionals if contract.positionals.empty?
      contract.preconditions.unshift(*parent.preconditions)
      contract.postconditions.unshift(*parent.postconditions)
      contract.return_constraint = parent.return_constraint unless contract.return_constraint
      contract.allowed_exceptions.unshift(*parent.allowed_exceptions)
      contract.observed.unshift(*parent.observed.reject do |observation|
        contract.observed.any? do |own|
          own.name == observation.name
        end
      end)
    end

    def wrap_contract(name, contract)
      return if contract.instance_variable_defined?(:@wrapped)

      original = instance_method(name)

      contract.method_source_location = original.source_location
      visibility = if private_method_defined?(name)
                     :private
                   else
                     protected_method_defined?(name) ? :protected : :public
                   end
      @__contracts_hook = true
      define_method(name) do |*args, **kwargs, &block|
        Contracts.invoke(self, contract, args, kwargs, block) do
          original.bind_call(self, *args, **kwargs, &block)
        end
      end
      send(visibility, name)
      contract.instance_variable_set(:@wrapped, true)
    ensure
      @__contracts_hook = false
    end

    def wrap_initialize_for_invariants
      return if @__contracts_initialize_wrapped

      original = instance_method(:initialize)
      @__contracts_hook = true
      define_method(:initialize) do |*args, **kwargs, &block|
        original.bind_call(self, *args, **kwargs, &block).tap do
          Contracts.check_invariants!(self) if Contracts.configuration.check_invariants_after_initialize && Contracts.configuration.invariant_checking != :disabled
        end
      end
      private :initialize
      @__contracts_initialize_wrapped = true
    ensure
      @__contracts_hook = false
    end
  end

  module InstanceMethods
    def check_contract_invariants! = Contracts.check_invariants!(self)
  end

  module SingletonClassMethods
    def contract_singleton(name, **options, &)
      singleton_class.extend(ClassMethods)
      singleton_class.declare_contract(name, :singleton, options, &)
    end

    def singleton_method_added(name)
      return if @__contracts_hook

      contract = Contracts.registry.find(singleton_class, name, method_type: :singleton)
      singleton_class.wrap_contract(name, contract) if contract && contract.owner == singleton_class
      super
    end
  end
end
