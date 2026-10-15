# ``Swiftpothesis``

Property-based testing for Swift Testing, with Hypothesis-style shrinking.

## Overview

A property-based test states something that should hold for every input, and Swiftpothesis searches for an input where it doesn't:

```swift
import Swiftpothesis
import Testing

@Test func shellQuotingRoundTrips() async {
    await forAll(String.arbitrary) { string in
        #expect(try runShell("printf %s \(string.shellQuoted)") == string)
    }
}
```

When a property fails, Swiftpothesis shrinks the failing input to a minimal one, such as the single string `"'"`, and reports it through Swift Testing with everything needed to reproduce it. The next run replays the failure first.

Swiftpothesis shrinks the way [Hypothesis](https://hypothesis.readthedocs.io) does: it records the random choices that produced an input and simplifies those, rather than the input itself. Every generator shrinks well, including ones built with `map`, `filter`, and `flatMap`, and no generator needs a hand-written shrinker.

## Topics

### Essentials

- <doc:GettingStarted>
- ``forAll(_:id:settings:sourceLocation:isolation:_:)``
- ``forAll(id:settings:sourceLocation:isolation:_:)-(_,_,_,_,(T)->Void)``
- ``PropertyResult``
- ``assume(_:_:)``
- ``note(_:)``

### Drawing While a Property Runs

- ``forAll(id:settings:sourceLocation:isolation:_:)-(_,_,_,_,(TestCase)->Void)``
- ``TestCase``

### Generators

- ``Generator``
- ``Arbitrary``
- ``zip(_:)``
- ``AnyGenerator``
- ``Generators``
- ``Source``
- ``Rejection``

### Stateful Testing

- <doc:StatefulTesting>
- ``StateMachine``
- ``check(_:steps:id:settings:sourceLocation:isolation:)``
- ``Scheduler``

### Reproducing Failures

- <doc:ReproducingFailures>
- ``ExampleDatabase``
- ``DirectoryDatabase``
- ``InMemoryDatabase``
- ``ChoiceSequence``

### Configuration

- ``Settings``
- ``PropertySettingsTrait``
- ``Phase``
- ``HealthCheck``

### Statistics and Search

- ``label(_:)``
- ``target(_:label:)``

### Explanation

- <doc:HowShrinkingWorks>
