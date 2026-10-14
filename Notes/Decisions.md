# Design Decisions

Contributor-facing notes on why Swiftpothesis is built the way it is. User documentation lives in the DocC catalog.

## 1. Native engine with internal shrinking

**Decision.** Swiftpothesis has its own engine. Generators draw primitive choices from a `Source`; the engine records them as a choice sequence and shrinks failures by simplifying the sequence and replaying the generator, as Hypothesis does.

**Alternatives.**
- Type-directed shrinking (QuickCheck, SwiftCheck): shrinking is lost through `flatMap`, and shrunk values can violate generator invariants.
- Integrated rose-tree shrinking (Hedgehog, fast-check, PropertyBased): shrinking survives `map` but degrades through `flatMap`.
- Sample trees (falsify) or reflective generators (Exhaust): newer, less proven, harder to explain.
- A client of the Hegel engine: kept as a possible optional backend for the future.

**Consequences.**
- Users never write shrinkers; shrinking works through `flatMap` and `filter`; shrunk values satisfy their generator.
- The failure database stores choice sequences, not values.
- Generators must encode choices so that smaller means simpler. Built-in generators do; custom `Generator` conformances must.
- A saved sequence reproduces only while its generators draw choices in the same order.

**Determinism.** Shrinking must be deterministic: the same failing sequence and settings always shrink to the same result. Shrink passes may use randomness only if it is seeded deterministically from the run.

**Customizing shrinking.** Value-level shrinkers (`(Value) -> [Value]`) don't fit, because a candidate value can't generally be mapped back to choices. Shrinking is instead customized through generation:
- The order of alternatives: `oneOf` shrinks toward its first generator, so `.oneOf(.just(simple), general)` shrinks toward `simple`.
- Shrink targets on primitives, such as integers that shrink toward a chosen value rather than zero (planned).
- Per-property generator overrides by key path in derived generators, such as overriding `\.name` in an `@Arbitrary` struct (planned with the derive macro).
- A modifier that disables shrinking for a sub-generator (planned).
