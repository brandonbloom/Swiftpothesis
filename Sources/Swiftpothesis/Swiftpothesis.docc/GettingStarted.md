# Getting Started

Write your first property and read its failure report.

## Add the package

Add Swiftpothesis to your package's dependencies, and to a test target:

```swift
dependencies: [
    .package(url: "https://github.com/brandonbloom/Swiftpothesis.git", branch: "main"),
],
targets: [
    .testTarget(
        name: "MyLibraryTests",
        dependencies: ["MyLibrary", .product(name: "Swiftpothesis", package: "Swiftpothesis")]),
]
```

## Write a property

A property is a Swift Testing test that calls ``forAll(_:settings:sourceLocation:isolation:_:)`` with generators for its inputs. Check the inputs with `#expect` and `#require`, as in any test:

```swift
import Swiftpothesis
import Testing

@Test func sortingIsIdempotent() async {
    await forAll([Int].arbitrary(Int.arbitrary(in: -100...100))) { array in
        #expect(array.sorted().sorted() == array.sorted())
    }
}
```

Types that conform to ``Arbitrary`` can be requested by type alone:

```swift
@Test func additionCommutes() async {
    await forAll { (a: Int, b: Int) in
        #expect(a &+ b == b &+ a)
    }
}
```

## Read a failure

Suppose a property is wrong:

```swift
@Test func everyArrayIsShort() async {
    await forAll([Int].arbitrary(Int.arbitrary(in: 0...1000))) { array in
        #expect(array.allSatisfy { $0 < 50 })
    }
}
```

Swiftpothesis finds a counterexample, shrinks it, and reports two issues. The first is your own expectation failing on the simplest input, with Swift Testing's usual detail. The second, at the `forAll` call, summarizes the run:

```
Property falsified after 3 examples.
Counterexample: [50]
Choices: […]
Reproduce with SWIFTPOTHESIS_SEED=…, or rerun to replay it from the database.
```

Issues recorded while searching and shrinking are held back, so a failure reads the same as an example-based test that failed on `[50]`.

## Next steps

- Generate your own types by conforming them to ``Arbitrary``, composing generators with ``zip(_:)`` and ``Generator/map(_:)``.
- Test a system with a model of it: <doc:StatefulTesting>.
- Understand how failures are reproduced: <doc:ReproducingFailures>.
