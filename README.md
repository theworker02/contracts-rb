# contracts-rb

[![Gem Version](https://badge.fury.io/rb/contracts-rb.svg)](https://rubygems.org/gems/contracts-rb)
[![CI](https://github.com/magnexis/contracts-rb/actions/workflows/ci.yml/badge.svg)](https://github.com/magnexis/contracts-rb/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.txt)
[![Ruby 3.1+](https://img.shields.io/badge/Ruby-3.1%2B-CC342D.svg)](https://www.ruby-lang.org/)

<p align="center">
  <a href="https://github.com/magnexis/contracts-rb">
    <img src="assets/contracts-rb-logo.png" alt="contracts-rb" width="760">
  </a>
</p>

`contracts-rb` adds small, explicit behavioral contracts to Ruby without imposing a type system. It supports parameter and return constraints, preconditions, postconditions, object invariants, state snapshots, mutation policies, exception declarations, introspection, and a dependency-free CLI.

**Official repository:** [github.com/magnexis/contracts-rb](https://github.com/magnexis/contracts-rb)

**RubyGems:** [rubygems.org/gems/contracts-rb](https://rubygems.org/gems/contracts-rb)

## Why contracts-rb?

Ruby tests describe expected examples; contracts keep critical method promises executable at runtime. Use them for domain boundaries, money movement, state transitions, service objects, and public library APIs. They are not a replacement for ordinary tests, schema validation, or authorization.

## Install

Install the official package from [RubyGems: `contracts-rb`](https://rubygems.org/gems/contracts-rb).

```ruby
gem "contracts-rb", "~> 0.1"
require "contracts"
```

## Five-minute example

```ruby
class Account
  include Contracts
  attr_reader :balance
  invariant("balance is non-negative") { balance >= 0 }

  contract :withdraw do
    params amount: Numeric
    requires("amount is positive") { |amount:| amount.positive? }
    requires("enough funds") { |amount:| amount <= balance }
    changes :balance
    returns Numeric
    ensures { |result, before:| balance == before.balance - result }
  end

  def initialize(balance:) = @balance = balance
  def withdraw(amount:) = (@balance -= amount)
end
```

Constraints include `Contracts.nilable`, `any`, `all`, `matching`, `range`, `one_of`, `array_of`, `hash_of`, `length`, `respond_to`, `duck_type`, `anything`, `nothing`, and `predicate`.

## Stateful contracts

Use `observe` to capture relevant receiver fields; `changes` permits a subset, `must_change` requires a transition, and `pure`/`changes_nothing` permits none. Snapshots are immutable (`before.balance`, `before[:balance]`, `before.metadata`) and `deep: true` protects nested arrays and hashes. Invariants run after initialization and around contracted methods by default. `Contracts.check_invariants!(object)` is available for explicit checks.

## Constraint reference

| Factory | Example | Meaning |
|---|---|---|
| `nilable` | `Contracts.nilable(String)` | `String` or `nil` |
| `any` | `Contracts.any(String, Symbol)` | any supplied constraint |
| `matching` | `Contracts.matching(/\A[a-z]+\z/i)` | string matching a regex |
| `range` | `Contracts.range(18..120)` | value inside a range |
| `one_of` | `Contracts.one_of(:draft, :published)` | one literal value |
| `array_of` | `Contracts.array_of(String)` | array whose elements match |
| `hash_of` | `Contracts.hash_of(Symbol, Numeric)` | hash with matching keys/values |
| `all` | `Contracts.all(String, Contracts.matching(/A/))` | every nested constraint matches |
| `length` | `Contracts.length(min: 1, max: 80)` | `size`/`length` within bounds |

## Runtime configuration

```ruby
Contracts.configure do |config|
  config.enabled = true
  config.failure_mode = :raise       # :raise, :warn, :log, :collect
  config.sample_rate = 1.0
  config.invariant_checking = :contracted_methods
  config.snapshot_strategy = :declared
  config.undeclared_exceptions = :ignore
end
```

For production, use sampling and a `:log` or `:collect` failure mode where an exception would be too disruptive. Sensitive parameter names are redacted from errors by default.

## Exceptions and inheritance

Declare exceptions with `raises PaymentError`; use `on_raise(PaymentError) { |error, before:| ... }` for rollback guarantees. Set `undeclared_exceptions` to `:warn` or `:violate` to enforce exception declarations. Inheritance mode defaults to `:merge`, applying parent parameter, precondition, postcondition, return, and observation rules to overriding child contracts. `:strict` rejects structural parameter constraint changes.

## Configuration and production use

```ruby
Contracts.configure do |config|
  config.enabled = true
  config.failure_mode = :log # :raise, :warn, :log, :collect
  config.sample_rate = 0.05
  config.undeclared_exceptions = :violate # :ignore, :warn, :violate
end
```

Errors avoid parameter values by default. Set `include_values_in_errors` only in trusted environments. Contracts complement tests and domain validation; use them for durable API promises and high-value invariants, not every local assertion.

## Tooling

`bundle exec contracts version`, `inspect`, `validate`, `doctor`, and `docs --format markdown|json --output PATH` are available. Load application code with `--require ./lib/my_app`.

```sh
bundle exec contracts inspect BankAccount#withdraw --require ./examples/banking/bank_account
bundle exec contracts docs --require ./examples/banking/bank_account --format markdown --output docs/contracts
bundle exec contracts doctor --require ./lib/my_app
```

`require "contracts/rspec"` provides basic RSpec matchers when RSpec is installed. `require "contracts/rails"` installs a lightweight optional Railtie.

## Compatibility

Ruby 3.1+. Rails is optional. The core is plain Ruby and has no runtime dependencies.

## Limitations

0.1.0 wraps declared instance methods directly; its explicit singleton API is experimental. Deep snapshots, static implication proofs for inheritance, and Rails instrumentation are intentionally deferred.

## Development

```sh
bundle install
bundle exec rake spec
gem build contracts-rb.gemspec
```

MIT licensed. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## Release process

Maintainers validate with `bundle exec rubocop .`, `bundle exec rspec`, and `bundle exec rake build`. The resulting `contracts-rb-<version>.gem` is attached to the matching GitHub release and published through an authenticated RubyGems session.

## Benchmark methodology

Run `bundle exec ruby benchmark/runtime_overhead.rb` on the deployment Ruby and hardware. Compare the included uncontracted and parameter/return-contracted methods; do not extrapolate those measurements to contracts that capture state or execute expensive predicates.
