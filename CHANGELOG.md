# Changelog

## Unreleased

## 0.4.0 - 2026-08-14

- Added `Contracts.all` to require every nested constraint to match.
- Added `Contracts.length(min:, max:, exactly:)` for String, Array, Hash, and other sized values.

## 0.3.0 - 2026-08-11

- Enforce `must_change` `from:` and `to:` bounds for scalar and array values.
- Raise `Contracts::MutationViolation` when required change bounds fail.

## 0.2.0 - 2026-08-04

- Added `Contracts::Constraints::Tuple` for fixed-length heterogeneous arrays.
- Added `Contracts::Constraints::Shape` for required and optional hash-key contracts.
- Added `Contracts::Constraints.tuple` and `.shape` constructors.
- Added strict extra-key handling with an opt-in `allow_extra` mode.
- Added structured constraint serialization through `to_h`.
- Corrected gem metadata links to the current `theworker02/contracts-rb` repository.

## 0.1.2 - 2026-07-30

- Corrected package metadata links to use the repository's `master` branch.

## 0.1.1 - 2026-07-30

- Restored Ruby 3.1 compatibility for snapshot argument handling and `Set` support.
- Added the Linux platform to the lockfile and constrained development dependencies for the supported Ruby matrix.
- Prevented RuboCop from scanning Bundler-installed dependencies in CI.

## 0.1.0

- Added release-quality package metadata, build task, generated contract documentation, and release workflow.
- Added the official contracts-rb logo asset.
- Initial release: core behavioral contracts, constraints, invariants, snapshots, registry, CLI, and optional integrations.
