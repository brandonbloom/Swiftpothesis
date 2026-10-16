# Swiftpothesis

Property-based testing for Swift: generators, Hypothesis-style integrated shrinking, a failure database, and stateful (model-based) testing, built on Swift Testing and Swift 6 strict concurrency.

Keywords: property-based testing, generative testing, QuickCheck, Hypothesis, shrinking, model-based testing, Swift Testing.

> **Status: alpha.** Swiftpothesis follows [StableVer](https://github.com/brandonbloom/stablever). Until 1.0, every feature is alpha and may change without notice.

**Documentation:** https://brandonbloom.github.io/Swiftpothesis/documentation/swiftpothesis/

## Example

```swift
import Swiftpothesis
import Testing

@Test func reversingTwiceIsIdentity() async {
    await forAll { (array: [Int]) in
        #expect(array.reversed().reversed() == array)
    }
}
```

## Installation

Swift 6.4 or later, on macOS, iOS, tvOS, watchOS, or visionOS 26 or later.

```swift
dependencies: [
    .package(url: "https://github.com/brandonbloom/Swiftpothesis.git", exact: "0.1.0"),
],
```

Then add `.product(name: "Swiftpothesis", package: "Swiftpothesis")` to your test target's dependencies.

Pin an exact version: under StableVer, every 0.x release may change alpha features.

## Development

The repository uses [mise](https://mise.jdx.dev) for tools and tasks:

```sh
mise run test           # swift test
mise run ci             # everything CI checks
mise run docs-preview   # build the DocC site and serve it locally
```
