import Testing

/// Tests that a property holds for generated values.
///
/// Call `forAll` inside a Swift Testing test. The property body checks its arguments with
/// `#expect` and `#require`, or by throwing:
///
/// ```swift
/// @Test func reversingTwiceIsIdentity() async {
///     await forAll([Int].arbitrary(Int.arbitrary(in: 0...100))) { array in
///         #expect(array.reversed().reversed() == array)
///     }
/// }
/// ```
///
/// While searching and shrinking, issues the property records are held back. When a failure is
/// found and shrunk, `forAll` runs the property once more on the simplest failing values, so
/// their issues are recorded as usual, and records one more issue, at the call site, that shows
/// the counterexample and how to reproduce it.
///
/// Like `#expect`, `forAll` lets the test continue after a failure. To stop the test instead, as
/// `#require` does, call ``PropertyResult/require()`` on the result.
///
/// - Parameters:
///   - generators: The generators for the property's arguments.
///   - examples: Arguments to test before any generated ones, such as earlier counterexamples
///     kept as regression tests. They're values, not choices, so they survive changes to the
///     generators. A failing example is reported without shrinking.
///   - id: Identifies this property within its test, so its saved failures replay. Defaults
///     to the property's position among the test's properties.
///   - settings: Options for this property. Defaults to the settings of the running test.
///   - sourceLocation: Where to attribute the summary issue.
///   - isolation: The actor the property runs on. Defaults to the caller's.
///   - property: The property, which fails by recording an issue or throwing an error, and can
///     discard its arguments with ``assume(_:_:)``.
/// - Returns: The outcome, already reported if it's a failure.
@discardableResult
public func forAll<each G: Generator>(
    _ generators: repeat each G,
    examples: [(repeat (each G).Value)] = [],
    id: String? = nil,
    settings: Settings = .current,
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation,
    _ property: (repeat (each G).Value) async throws -> Void
) async -> PropertyResult {
    await check(
        zip(repeat each generators), examples: examples, id: id, settings: settings,
        sourceLocation: sourceLocation, isolation: isolation
    ) { (values: (repeat (each G).Value)) in
        try await property(repeat each values)
    }
}

/// Tests that a property holds for generated values of ``Arbitrary`` types.
///
/// ```swift
/// @Test func additionCommutes() async {
///     await forAll { (a: Int, b: Int) in
///         #expect(a &+ b == b &+ a)
///     }
/// }
/// ```
///
/// See ``forAll(_:examples:id:settings:sourceLocation:isolation:_:)`` for details.
@discardableResult
public func forAll<each T: Arbitrary>(
    examples: [(repeat each T)] = [],
    id: String? = nil,
    settings: Settings = .current,
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation,
    _ property: (repeat each T) async throws -> Void
) async -> PropertyResult {
    await check(
        zip(repeat (each T).arbitrary), examples: examples, id: id, settings: settings,
        sourceLocation: sourceLocation, isolation: isolation
    ) { (values: (repeat each T)) in
        try await property(repeat each values)
    }
}

/// Tests that a property holds, drawing values while it runs.
///
/// Use this form when the values to test depend on what the code under test does. Each value
/// drawn from `test` is shown in the failure report, in order.
///
/// ```swift
/// @Test func deletingAnyCreatedItem() async throws {
///     await forAll { test in
///         let ids = try await store.create(try test.draw([String].arbitrary(count: 1...10)))
///         try await store.delete(try test.draw(element(of: ids)))
///         #expect(try await store.count == ids.count - 1)
///     }
/// }
/// ```
///
/// See ``forAll(_:examples:id:settings:sourceLocation:isolation:_:)`` for details.
@discardableResult
public func forAll(
    id: String? = nil,
    settings: Settings = .current,
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation,
    _ property: (TestCase) async throws -> Void
) async -> PropertyResult {
    await Engine(id: id, settings: settings, sourceLocation: sourceLocation).run(
        isolation: isolation
    ) {
        testCase, _ in
        try await property(testCase)
    }
}

/// Discards the current test case unless a condition holds.
///
/// Use assumptions for preconditions that are hard to build into generators. Discarded test
/// cases don't count toward ``Settings/maxExamples``, and a property that discards most of its
/// test cases fails the ``HealthCheck/filterTooMuch`` health check.
///
/// - Throws: ``Rejection`` when `condition` is false.
public func assume(_ condition: Bool, _ comment: Comment? = nil) throws(Rejection) {
    if !condition { throw Rejection(.assumption, comment: comment?.rawValue) }
}

/// Adds a message to the report of a failing example.
///
/// Notes are discarded for passing examples, so they cost little. Use them to show intermediate
/// values that explain a failure.
public func note(_ message: @autoclosure () -> String) {
    PropertyContext.current?.notes.append(message())
}

/// Counts the current test case under a label, for the run's statistics.
///
/// Labels show how generated values are distributed, such as how many arrays were empty. The
/// counts appear in ``PropertyResult/labels``, and in a "Property statistics" attachment on the
/// test.
public func label(_ label: String) {
    PropertyContext.current?.labels.insert(label)
}

/// Guides generation toward test cases with higher scores.
///
/// In the ``Phase/target`` phase, after generating, the engine mutates the highest-scoring
/// test case for each label, keeping mutations that score higher. This hill climbs toward
/// examples that maximize the score, such as a queue's peak length, and finds failures that
/// only extreme inputs reach. The best scores appear in ``PropertyResult/targets``.
public func target(_ score: Double, label: String = "") {
    PropertyContext.current?.targets[label] = score
}

// The `forAll` overloads funnel through here, rather than forwarding closures to each other,
// which crashes at run time ("freed pointer was not the last allocation") as of Swift 6.4.
private func check<G: Generator>(
    _ generator: G,
    examples: [G.Value],
    id: String?,
    settings: Settings,
    sourceLocation: SourceLocation,
    isolation: isolated (any Actor)?,
    _ property: (G.Value) async throws -> Void
) async -> PropertyResult {
    // The engine runs the examples before it returns.
    await withoutActuallyEscaping(property) { property in
        let explicit = examples.map { value in
            ExplicitExample(label: String(reflecting: value)) { context in
                context.description = String(reflecting: value)
                try await property(value)
            }
        }
        return await Engine(id: id, settings: settings, sourceLocation: sourceLocation).run(
            isolation: isolation, explicit: explicit
        ) {
            testCase, context in
            let value = try testCase.draw(generator)
            context.description = String(reflecting: value)
            try await property(value)
        }
    }
}
