# Buyer evaluation â€” contracts-rb

## Goal

In 15â€“45 minutes, verify the Product builds or runs as documented and that proprietary notices are present.

## Steps

1. Confirm root `LICENSE` is proprietary and `ACQUISITION.md` exists.
2. Skim `README.md` install/run claims.
3. Execute:

```
```ruby
gem "contracts-rb", "~> 0.4"
require "contracts"
```
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
```ruby
Contracts.configure do |config|
  config.enabled = true
  config.failure_mode = :log # :raise, :warn, :log, :collect
  config.sample_rate = 0.05
  config.undeclared_exceptions = :violate # :ignore, :warn, :violate
end
```

4. Run tests if present (`npm test`, `pytest`, `cargo test`, `go test ./...`, etc.).
5. Record README vs observed behavior gaps in workpapers.

## Pass criteria

- [ ] Clone succeeds
- [ ] Documented happy path works **or** failure is explained
- [ ] Minimal path needs no surprise secrets
- [ ] License notices intact

*Updated: 2026-09-22*
