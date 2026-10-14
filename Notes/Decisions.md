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

## 2. Choice encoding

**Decision.** One primitive, `Source.choose(atMost:) -> UInt64`, where smaller is simpler. Generators layer on it: integers choose a sign and a distance from their shrink target; booleans choose from `0...1`; arrays choose "continue?" (0 stops) before each element span; `oneOf` and `element(of:)` choose an index; strings choose a scalar class, then a scalar. `Source.draw(_:)` draws a value from another generator.

**Modes.** Generating chooses randomly, biased toward 0, the bound, and small values. Replaying clamps recorded choices to the current bound, and chooses 0 past the end of the recording. More than 8,192 choices in one test case is an overrun, which discards it.

**Alternatives.** Hypothesis records typed choices (integer, float, string, bytes, boolean) with their constraints, which lets its shrinker and database understand each choice. Typed choices can replace `choose(atMost:)` later, chiefly to improve float and string shrinking.

**Naming.** `draw` takes a value from a generator, after Hypothesis's `draw` and rapid's `Draw`. `choose` makes a primitive choice, matching "choice sequence".

**Visibility.** `Source` is public so custom generators can make primitive choices. That ties the encoding to the public API, which is acceptable while everything is alpha.

**Naming.** "Generator" has its property-based-testing meaning (QuickCheck, test.check, Kotest, rapid): a recipe for one value. It conflicts with the iterator meaning in Python, JavaScript, and pre-Swift-3 `GeneratorType`; the protocol's docstring says so. `Strategy` (Hypothesis, proptest) was the main alternative.

## 3a. `TestCase`: drawing while a property runs

**Decision.** The primitive process is the running test case, not a generator. `TestCase` is a public, `Sendable` handle to a test case's choices: `draw(_:)` a value from a generator, `choose(atMost:)` a primitive choice, or `stream(of:)` an endless sequence of values drawn on demand. `forAll { test in … }` exposes it to properties.

**Layers.** Choices (`Source.choose`) → `Source` (one test case's recorded stream) → `TestCase` (the live, lockable handle) → the engine's test function. `Generator` stays a pure function of a `Source`. `forAll(generators…)` draws everything up front, `check(StateMachine)` alternates drawing and running, and `Scheduler` and streams are objects that hold a `TestCase` and choose later. All of these are defined on the `TestCase` layer.

**Why.** Generators finish before the property runs, so they can't express choices that depend on the system's results, lazy inputs, or schedule orders. Hypothesis (`st.data()`), rapid (`t.Draw`), and fast-check (`fc.gen()`) have the same escape hatch.

**Lifetime.** A `TestCase` is valid only while its property runs. The engine closes it afterward, and later use is a precondition failure rather than silently drawing into another test case.

**Reporting.** Each `TestCase.draw` is a span and is listed in failure reports in order ("Draw 1: …").

**Naming.** `TestCase` follows Hegel and doesn't collide with Swift Testing's nested `Test.Case`. Alternatives considered: `Draws`, `Trial`, `Example`.

## Versioning

Swiftpothesis follows [StableVer](https://github.com/brandonbloom/stablever). Until 1.0, every feature is alpha: subject to breaking changes at any time.

## 3. The `Generator` protocol

**Decision.**

```swift
public protocol Generator<Value>: Sendable {
    associatedtype Value: Sendable
    func generate(from source: inout Source) throws(Rejection) -> Value
}
```

- **A protocol, not a closure-wrapping `Gen<Value>` struct** (swift-gen, PropertyBased, SwiftCheck). Combinators return concrete types in the `Generators` namespace, which the compiler can specialize; users write `some Generator<T>`, and `AnyGenerator` erases when needed. Cost: concrete types leak into spelled-out signatures, notably `Arbitrary` conformances.
- **Generators are `Sendable`**, so they can live in `static let`s and traits. Closures passed to combinators must be `@Sendable`.
- **Values are `Sendable`.** Generated values should be pure values; `Sendable` is the floor the compiler can check. It lets properties hand inputs to tasks and actors, and leaves room for running test cases in parallel. To test a non-`Sendable` type, generate a `Sendable` description of it and construct the instance inside the property. `Arbitrary` refines `Sendable` accordingly.
- **`inout Source`.** Generation is one sequential pass with no shrink tree, and `inout` makes that ownership explicit without a reference type.
- **Typed `throws(Rejection)`.** The only way generation fails is by discarding the test case.
