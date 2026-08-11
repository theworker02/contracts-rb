# frozen_string_literal: true
require "spec_helper"

RSpec.describe "stateful contracts" do
  it "checks initialization invariants and produces immutable deep snapshots" do
    klass = Class.new do
      include Contracts
      attr_reader :balance, :events
      invariant("non-negative") { balance >= 0 }
      contract(:deposit) do
        observe :balance
        observe :events, deep: true
        changes :balance, :events
        must_change :balance
        ensures { |amount, before:| before.events.empty? && balance == before.balance + amount }
      end
      def initialize(balance:) = (@balance = balance; @events = [])
      def deposit(amount:) = (@balance += amount; @events << amount; amount)
    end
    expect { klass.new(balance: -1) }.to raise_error(Contracts::InvariantViolation)
    account = klass.new(balance: 1)
    expect(account.deposit(amount: 2)).to eq(2)
  end

  it "rejects unpermitted observed mutations" do
    klass = Class.new do
      include Contracts
      attr_reader :balance, :status
      contract(:call) { observe :balance, :status; changes :balance }
      def initialize = (@balance = 0; @status = :active)
      def call = (@balance += 1; @status = :closed)
    end
    expect { klass.new.call }.to raise_error(Contracts::MutationViolation)
  end

  it "enforces must_change from bounds" do
    klass = Class.new do
      include Contracts
      attr_reader :status
      contract(:transition) do
        observe :status
        changes :status
        must_change :status, from: :active
      end
      def initialize = @status = :active
      def transition = @status = :closed
    end
    expect(klass.new.transition).to eq(:closed)

    invalid = Class.new do
      include Contracts
      attr_reader :status
      contract(:transition) do
        observe :status
        changes :status
        must_change :status, from: :active
      end
      def initialize = @status = :pending
      def transition = @status = :closed
    end
    expect { invalid.new.transition }.to raise_error(Contracts::MutationViolation, /from/)
  end

  it "enforces must_change to bounds with scalar and array values" do
    klass = Class.new do
      include Contracts
      attr_reader :status
      contract(:close) do
        observe :status
        changes :status
        must_change :status, to: :closed
      end
      def initialize = @status = :active
      def close = @status = :closed
    end
    expect(klass.new.close).to eq(:closed)

    array_bound = Class.new do
      include Contracts
      attr_reader :status
      contract(:archive) do
        observe :status
        changes :status
        must_change :status, to: [:archived, :deleted]
      end
      def initialize = @status = :active
      def archive = @status = :archived
    end
    expect(array_bound.new.archive).to eq(:archived)

    expect do
      Class.new do
        include Contracts
        attr_reader :status
        contract(:close) do
          observe :status
          changes :status
          must_change :status, to: :closed
        end
        def initialize = @status = :active
        def close = @status = :pending
      end.new.close
    end.to raise_error(Contracts::MutationViolation, /to/)
  end

  it "enforces must_change from and to bounds together" do
    klass = Class.new do
      include Contracts
      attr_reader :balance
      contract(:withdraw) do
        observe :balance
        changes :balance
        must_change :balance, from: 100, to: 50
      end
      def initialize = @balance = 100
      def withdraw = @balance = 50
    end
    expect(klass.new.withdraw).to eq(50)

    expect do
      Class.new do
        include Contracts
        attr_reader :balance
        contract(:withdraw) do
          observe :balance
          changes :balance
          must_change :balance, from: 100, to: 50
        end
        def initialize = @balance = 200
        def withdraw = @balance = 50
      end.new.withdraw
    end.to raise_error(Contracts::MutationViolation, /from/)
  end
end
