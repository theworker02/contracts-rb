# Structured constraints

Contracts-rb 0.2.0 adds optional structured constraints for fixed tuples and hash-shaped payloads.

Load the extension after the main gem:

```ruby
require "contracts"
require "contracts/structured"
```

## Tuple

```ruby
Coordinates = Contracts::Constraints.tuple(Float, Float)
Coordinates.matches?([41.3, -72.9]) # => true
```

A tuple requires an `Array` with the exact declared length and validates every position independently.

## Shape

```ruby
Payload = Contracts::Constraints.shape(
  required: {
    name: String,
    retries: Integer
  },
  optional: {
    tags: Contracts::Constraints::ArrayOf.new(String)
  }
)
```

Shapes reject missing required keys, invalid optional values, and unknown keys. Set `allow_extra: true` when additional keys are part of the contract.

```ruby
OpenPayload = Contracts::Constraints.shape(
  required: {name: String},
  allow_extra: true
)
```

Both constraints implement the normal Contracts-rb constraint interface: `matches?`, `description`, and `to_h`.

`Contracts.all` and `Contracts.length` live on the core gem (no extra require) for conjunctions and sized values:

```ruby
Contracts.all(String, Contracts.matching(/\A[A-Z]/)).matches?("OK")
Contracts.length(min: 2, max: 4).matches?("ab")
```

