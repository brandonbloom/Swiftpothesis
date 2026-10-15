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

**Decision.** A property is a call to `forAll` inside an ordinary Swift Testing test. There are three forms: generators, `Arbitrary` types by closure parameter, and `TestCase`. All are `async` and take `isolation: isolated (any Actor)? = #isolation`, so properties run on the caller's actor and needn't be `@Sendable` or `async` themselves. Parameter packs cover any number of generators.

**Expect and require.** `forAll` behaves like `#expect`: it records the failure and the test continues. It returns a `@discardableResult PropertyResult`, whose `require()` throws to end the test like `#require`. The thrown error is an `ExpectationFailedError`, obtained by failing a `#require` with its issue captured, so Swift Testing doesn't report it again. The result also exposes the counterexample, for testing generators and for tooling.

**Holding back issues.** Issues recorded while searching and shrinking are captured with `IssueHandlingTrait.provideScope`, which is public but async. This is why `forAll` is async-only.

**Engine shape.** The engine is a `Driver` state machine that proposes choice sequences and records outcomes, with a pull-based `Shrinker`; a loop runs each test case. Keeping the driver apart from execution lets a synchronous loop, parallel execution, or another backend reuse it.

**Sync overloads: built, then removed.** Sync overloads worked by having `.propertySettings()` install an issue handler that deferred to a task-local sink. That needed the trait on every test with a non-`await`ing property (including those in `async` tests, where such closures select the sync overload), printed every failing search step as a known issue when the trait was missing, and relied on Swift Testing calling issue handlers synchronously on the recording thread, which isn't documented. Their benefit, omitting `async` and `await`, didn't justify that. Revisit if Swift Testing gains synchronous scoped issue handling; the driver already supports a synchronous loop.

**Alternatives.**
- A macro (`@Property`, `#forAll`): a swift-syntax dependency, slower builds, hidden control flow. Possible later as sugar.
- `@Test(arguments:)`: arguments are fixed before the test runs, which rules out shrinking and the database.
- A throwing `forAll`, or a separate `requireForAll`: Swift can't overload on `throws`, and two names split one concept.
- `#require(forAll(…))`: reports the failure twice.

**Naming.** `forAll`, after QuickCheck, ScalaCheck, Kotest, and PropEr's `?FORALL`.

## 6. Which failures shrinking accepts

**Decision.** Shrinking adopts any simpler candidate that fails, whatever its reason. The goal is the smallest failing input, not the smallest input for the failure first found.

**Why.** "Same failure" can't be determined reliably. Two failures at one `#expect` can be different bugs, one bug can fail different lines for different inputs, and thrown Swift errors carry no location. A smaller failing input is the more useful report either way. QuickCheck, test.check, fast-check, proptest, Hedgehog, PropEr, and StreamData all shrink this way. Hypothesis instead distinguishes failures by exception type and raise location, using tracebacks, and shrinks each separately.

**Rare bugs.** Shrinking can move from a hard-to-find bug to an easy one, and after the easy one is fixed, random search may not find the rare one again. So when shrinking moves to a failure at a different origin (the first issue's source location, or the thrown error's type), it keeps the last example at the old origin, and the database saves those alongside the shrunk example. The next run replays them first. The summary notes when shrinking moved between origins.

**Later.** Reporting several distinct failures per run, as Hypothesis's `report_multiple_bugs` does, could build on the same bookkeeping.

## 7. Settings and time

**Decision.** One `Settings` value struct: `maxExamples` (100), `seed` (random), `derandomize` (off), `maxShrinkAttempts` (1000), `database` (the cache-directory database), `phases` (all), `suppressedHealthChecks` (none), `deadline` (60 s), `slowWarning` (10 s), and `timeLimit` (none). Precedence, lowest to highest: defaults, `SWIFTPOTHESIS_*` environment variables, `.propertySettings { … }` traits (suite, then test), and `forAll`'s `settings:` argument. Explicit code wins over the environment.

**Profiles** (named presets such as `ci`, chosen by `SWIFTPOTHESIS_PROFILE`) are deferred until a second preset is worth naming.

**Deadlines were built early,** because timing is hard to retrofit into an engine.
- `deadline` limits one test case. A late test case fails, so shrinking finds the smallest slow input. Each test case races a timer in a task group and is cancelled at the deadline, while still running on the caller's actor. Cancellation is cooperative: a property that never suspends finishes first and is then reported as late. Swift Testing's `.timeLimit` trait remains the guard against real hangs.
- The default is a generous 60 s, because properties doing real I/O (FBF's sync simulation takes 2–5 s per test case) would otherwise fail by default. `slowWarning` (10 s) records one warning per property, naming the slowest test case, so slowness is noticed well before it fails.
- The first test case is exempt, since one-time setup makes it unrepresentative.
- While shrinking, a test case must exceed the deadline by 25% to count, so timing noise doesn't steer shrinking.
- If the shrunk example meets its deadline on replay, the failure is reported as flaky.
- `timeLimit` caps the generate phase; when it runs out, the property passes with fewer examples.

**Shrinking is limited by fuel, not time.** `maxShrinkAttempts` counts candidates run, so shrinking stays deterministic. When the fuel runs out, the report says the counterexample may not be minimal. Slow properties lower it. A shrinking time limit was rejected because it makes results depend on machine speed.

**Derandomize vs an explicit seed.** An explicit seed is one number shared by every property it applies to, for reproducing a failure or pinning a test. `derandomize` (or `SWIFTPOTHESIS_DERANDOMIZE=1`) seeds each property from its machine-independent identity (test ID plus property index or `id:`, not the file path), so a whole suite is deterministic with no configuration, and editing one test doesn't change another's seed. With both, the explicit seed salts every property's seed, so CI can rotate it. Derandomized runs test a fixed sample, so random runs should still happen elsewhere. The motivating case is a shared CI gate, where a random run finding an old bug fails unrelated changes.

## 8. The failure database

**Decision.** The database saves choice sequences: every shrunk failure, plus examples shrinking moved away from (decision 6). The next run replays them before generating, and deletes any that pass. It's a discardable cache; losing it only means failures must be found again.

**Key.** The test file's absolute path, the test's ID, and the property's index among the test's properties, or an explicit `id:` passed to `forAll` or `check`. Indexes survive edits elsewhere in the file, unlike line numbers; an explicit ID also survives reordering. The path keeps separate checkouts apart. Cases of a parameterized test share a key, since `Test.Case` has no public ID.

**Location.** The user's cache directory (`URL.cachesDirectory`: `~/Library/Caches/Swiftpothesis/examples` on Apple platforms, `$XDG_CACHE_HOME` or `~/.cache` on Linux), overridable with `SWIFTPOTHESIS_DATABASE`. One mechanism that works for `swift test`, Xcode, simulators, and devices, and needs no `.gitignore` entry. Worktrees don't share failures, so a fix in one can't delete another's saved failure; set `SWIFTPOTHESIS_DATABASE` to share deliberately.

**Alternatives.**
- The current directory: wrong under Xcode, and every consumer must ignore it.
- `.build/`, found by walking up to `Package.swift`: cleaned with the build, but needs a second mechanism for projects without a package manifest, and can't work on devices.
- Checking the database in: opaque, churning files. Not recommended.

**Formats.** Every file Swiftpothesis writes is JSON in an envelope: `{"format": …, "version": …, "data": …}`. Versions are calendar dates (`2026.10.15`), bumped whenever any format changes. Files from another format or version are ignored with a warning, never migrated.

**Later.** Pruning entries by age, and a read-only database of failures downloaded from CI.

## 9. State machines

**Decision.** Two protocols, neither refining the other, because the convenient one removes a capability rather than adding one.

- `SequentialMachine`: one `State` value holding the system and any model or replicas; `makeState() async throws`; `commands(for: State)`; `run(_:state: inout State)` performs and checks a command with `#expect`; `skip(_:)` marks a command that doesn't apply; `checkInvariants`, `finish(state:)` (a final settle-and-check step that shrinks and shows as "(finish)"), and `tearDown`. `check(_:steps:averageSteps:…)` runs it.
- `LinearizableMachine`: separate `Model` and `Sendable` `System`; `apply(_:to:) -> Response`; `next(_:after:response:)`; a pure `postcondition` returning `Bool`, since a linearizability search evaluates it for many candidate orders. `checkLinearizability` will run commands concurrently and search for an explaining order; it's a stub.

**Conversion, not subtyping.** A linearizable machine can always run sequentially (apply, then check the postcondition with `#expect`, then advance the model), so `machine.sequential` adapts it to a `SequentialMachine`. The reverse is impossible: a combined `run` can't be evaluated without running the system. So there's one sequential engine, and a parallel engine only linearizable machines can use.

**Why one `State`.** FBF's review: their commands come from the system's state (pending files, visible items), not from a model, and their properties compare replicas with each other and an oracle, with no model at all. A separate model and system made them mirror the file system into the model. Model-based users put both in one struct.

**Lengths.** Sequences continue with a uniform choice per step, giving geometric lengths with a set average: `averageSteps` (default 20) for machines, `averageCount` for collections (default a few past the minimum, as in Hypothesis). FBF's planted bug was missed at an average of ~10 steps and caught at ~30.

**Naming.** `SequentialMachine` and `LinearizableMachine` name what each can be checked for. "Parallel" was rejected because the linearizable machine also runs sequentially; "Model" because it's the linearizable machine's associated type, and sequential machines often have none.

**Alternatives.** Command objects (fast-check), rule methods with bundles (Hypothesis; would need a macro), a single protocol with optional linearizability (makes differential tests invent a `Response`).

## Versioning

Swiftpothesis follows [StableVer](https://github.com/brandonbloom/stablever). Until 1.0, every feature is alpha: subject to breaking changes at any time.
