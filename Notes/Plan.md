# Plan

Contributor-facing list of open work, roughly in the order it should happen. Design rationale for finished work lives in [Decisions.md](Decisions.md).

## Next

1. **Record the decisions made since 0.1.0 in Decisions.md.**
   - `withDuplicates`: copies come from the same generator's earlier values in the test case, and are either exact or nudge one choice by 1–3. Copies are recorded choices, so they shrink and replay. Precedent: jqwik's `injectDuplicates`, whose copies shrink poorly. Recording them as choices avoids that.
   - Fixed-arity `zip` for 2–5 generators alongside the variadic one. A parameter pack's tuple can't be destructured in a closure, and with two arguments `Swift.zip(_:_:)` outranks the variadic overload.
   - The explain phase runs only when the spans it finds match the property's argument count, so it never numbers spans inside a single argument.
   - Grids and images are a recipe, not an API, because Swift has no standard grid type. `Data.arbitrary` covers raw bytes.
2. **Make timing tests independent of runner speed.** Deadline tests use wall-clock sleeps with 100 ms deadlines and were widened twice for GitHub's shared runners. Measure deadlines against `VirtualClock` in tests, or inject the engine's clock, so they're deterministic.
3. **`@Arbitrary` derive macro** for structs and enums. The largest ergonomic gain, but it adds a swift-syntax dependency, which slows clean builds for every dependent. Needs a design review before 1.0, since it shapes how people write generators.

## Deferred

- **Named settings profiles**, such as a `ci` profile with more examples and no deadline, selected by environment variable.
- **Database keys for parameterized tests.** Swift Testing has no public `Test.Case` ID, so a parameterized test's cases share one saved-failure entry.
- **Hypothesis's lexicographic float encoding**, so doubles shrink toward simpler values within each kind.
- **`SWIFTPOTHESIS_REPLAY`**: replay one reported failure from an environment variable. Unclear whether it earns its place beside the seed and the database.
- **Hegel engine support**, as an optional engine.
