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

## 3. The `Generator` protocol

**Decision.**

```swift
public protocol Generator<Value>: Sendable {
    associatedtype Value: Sendable
    func generate(from source: inout Source) throws(Rejection) -> Value
}
```

- **A protocol, not a closure-wrapping `Gen<Value>` struct** (swift-gen, PropertyBased, SwiftCheck). Generators have concrete types the compiler can specialize. Type-owned constructors return them opaquely (`some Generator<T>`); leading-dot combinators must name theirs, so those types are public in the `Generators` namespace. `AnyGenerator` erases when needed.
- **Generators are `Sendable`**, so they can live in `static let`s and traits. Closures passed to combinators must be `@Sendable`.
- **Values are `Sendable`.** Generated values should be pure values; `Sendable` is the floor the compiler can check. It lets properties hand inputs to tasks and actors, and leaves room for running test cases in parallel. To test a non-`Sendable` type, generate a `Sendable` description of it and construct the instance inside the property. `Arbitrary` refines `Sendable` accordingly.
- **`inout Source`.** Generation is one sequential pass with no shrink tree, and `inout` makes that ownership explicit without a reference type.
- **Typed `throws(Rejection)`.** The only way generation fails is by discarding the test case.

**Naming.** "Generator" has its property-based-testing meaning (QuickCheck, test.check, Kotest, rapid): a recipe for one value. It conflicts with the iterator meaning in Python, JavaScript, and pre-Swift-3 `GeneratorType`; the protocol's docstring says so. `Strategy` (Hypothesis, proptest) was the main alternative.

## 3a. `TestCase`: drawing while a property runs

**Decision.** The primitive process is the running test case, not a generator. `TestCase` is a public, `Sendable` handle to a test case's choices: `draw(_:)` a value from a generator, `choose(atMost:)` a primitive choice, or `stream(of:)` an endless sequence of values drawn on demand. `forAll { test in … }` exposes it to properties.

**Layers.** Choices (`Source.choose`) → `Source` (one test case's recorded stream) → `TestCase` (the live, lockable handle) → the engine's test function. `Generator` stays a pure function of a `Source`. `forAll(generators…)` draws everything up front, `check(StateMachine)` alternates drawing and running, and `Scheduler` and streams are objects that hold a `TestCase` and choose later. All of these are defined on the `TestCase` layer.

**Why.** Generators finish before the property runs, so they can't express choices that depend on the system's results, lazy inputs, or schedule orders. Hypothesis (`st.data()`), rapid (`t.Draw`), and fast-check (`fc.gen()`) have the same escape hatch.

**Lifetime.** A `TestCase` is valid only while its property runs. The engine closes it afterward, and later use is a precondition failure rather than silently drawing into another test case.

**Reporting.** Each `TestCase.draw` is a span and is listed in failure reports in order ("Draw 1: …").

**Naming.** `TestCase` follows Hegel and doesn't collide with Swift Testing's nested `Test.Case`. Alternatives considered: `Draws`, `Trial`, `Example`.

## 4. How generators are spelled

**Decision.** Generators for a type's values are static members of that type:

- `T.arbitrary`, the `Arbitrary` requirement, generates any value. It's a property: a pure description with no side effects.
- `T.arbitrary(…)` methods narrow it, such as `Int.arbitrary(in: 0...9)` or `[Int].arbitrary(count: 1...5)`. Each takes at least one argument, so `T.arbitrary()` never duplicates `T.arbitrary`. A narrowed generator produces a subset of `T.arbitrary`'s values, possibly with different frequencies, and constructs them directly rather than filtering.
- A single obvious generator argument is unlabeled, as in `[Int].arbitrary(Int.arbitrary(in: 0...9))` and `Int?.arbitrary(…)`. Dictionaries label `keys:` and `values:`.
- Methods return opaque types (`some Generator<T>`), so concrete generator types for values are internal.
- Combinators not owned by a value type are leading-dot static members of `Generator`: `.oneOf`, `.weighted`, `.constant`, `.element(of:)`, `.recursive`; plus the free function `zip`.

Custom types follow the same pattern: conform to `Arbitrary`, and add `arbitrary(…)` methods for narrower values, usually built with `zip(…).map(…)`.

**Precedent.** `Int.random(in:)` and `Bool.random()` in the standard library.

**Alternatives.**
- Leading-dot members for everything (`.integers(in:)`, `.arrays(of:)`): short, but one flat namespace shared by every module, which scales poorly to custom and domain types, and unusable without type context.
- A `Gen` namespace: just as flat.
- Nested generator types (`Int.Values(in:)`): one spelling, but adds a nested type to every conforming type, requires type erasure in collections, and makes custom types write a struct.
- `.arb`: shorter, but an abbreviation. Offering both `arb` and `arbitrary` was rejected outright.

**Naming.** `.constant(_:)` replaces QuickCheck's jargon `just`, after SwiftUI's `Binding.constant`. `.weighted` replaces `frequency`.

**Cost.** Nested generators are verbose, such as `[[Int]].arbitrary([Int].arbitrary(Int.arbitrary(in: 0...9)))`. They're needed only when "any value" doesn't fit.

## 5. `forAll`

**Decision.** A property is a call to `forAll` inside an ordinary Swift Testing test. There are three forms (generators, `Arbitrary` types by closure parameter, and `TestCase`), each with a synchronous and an asynchronous overload. Async overloads take `isolation: isolated (any Actor)? = #isolation`, so properties run on the caller's actor and needn't be `@Sendable`. Parameter packs cover any number of generators.

**Expect and require.** `forAll` behaves like `#expect`: it records the failure and the test continues. It returns a `@discardableResult PropertyResult`, whose `require()` throws to end the test like `#require`. The thrown error is an `ExpectationFailedError`, obtained by failing a `#require` with its issue captured, so Swift Testing doesn't report it again. The result also exposes the counterexample, for testing generators and for tooling.

**Sync and async share one engine.** Swift has no `reasync`, so the engine is a `Driver` state machine that proposes choice sequences and records outcomes, with a pull-based `Shrinker`. The sync and async `run` loops only execute test cases. The same driver suits parallel execution or another backend later.

**Holding back issues.** Async properties capture issues with `IssueHandlingTrait.provideScope`, which is public but async-only. Sync properties capture them through a handler that `.propertySettings()` installs for the test, which defers to a task-local sink; this is quiet. Without the trait, sync properties fall back to `withKnownIssue`, so the search's failures are listed as known issues, and a warning names the fix. Note that in an async test, a closure without `await` selects the sync overload.

**Alternatives.**
- A macro (`@Property`, `#forAll`): a swift-syntax dependency, slower builds, hidden control flow. Possible later as sugar.
- `@Test(arguments:)`: arguments are fixed before the test runs, which rules out shrinking and the database.
- A throwing `forAll`, or a separate `requireForAll`: Swift can't overload on `throws`, and two names split one concept.
- `#require(forAll(…))`: reports the failure twice.
- Async-only: forces `async` on tests that aren't.

**Naming.** `forAll`, after QuickCheck, ScalaCheck, Kotest, and PropEr's `?FORALL`.

## Versioning

Swiftpothesis follows [StableVer](https://github.com/brandonbloom/stablever). Until 1.0, every feature is alpha: subject to breaking changes at any time.
