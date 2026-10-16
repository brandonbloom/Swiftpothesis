# Swiftpothesis

Property-based testing for Swift: generators, Hypothesis-style integrated shrinking, a failure database, and stateful (model-based) testing, built on Swift Testing and Swift 6 strict concurrency.

Keywords: property-based testing, generative testing, QuickCheck, Hypothesis, shrinking, model-based testing, Swift Testing.

> [!WARNING]
> **Swiftpothesis is a preview.** Its APIs, behavior, and file formats are unstable and will change, sometimes without notice. It follows [StableVer](https://github.com/brandonbloom/stablever): until 1.0, every feature is alpha. Pin an exact version, and expect to update your tests when you upgrade.

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
    .package(url: "https://github.com/brandonbloom/Swiftpothesis.git", exact: "0.1.1"),
],
```

Then add `.product(name: "Swiftpothesis", package: "Swiftpothesis")` to your test target's dependencies.

## Development

The repository uses [mise](https://mise.jdx.dev) for tools and tasks:

```sh
mise run test           # swift test
mise run ci             # everything CI checks
mise run docs-preview   # build the DocC site and serve it locally
```

## License

Swiftpothesis is available under the [MIT License](LICENSE).
