/// The outcome of testing a property.
///
/// ``forAll(_:settings:sourceLocation:isolation:_:)`` has already reported any failure through
/// Swift Testing by the time it returns its result, so most tests ignore the result. Use it to
/// stop a test when a property fails, as `#require` does:
///
/// ```swift
/// try forAll(Int.arbitrary) { x in
///     #expect(parse(format(x)) == x)
/// }.require()
/// ```
///
/// or to inspect the counterexample, such as when testing a generator.
public struct PropertyResult: Sendable {
    /// A shrunk failing example.
    public struct Falsification: Sendable {
        /// The failing values, as shown in the failure report.
        public var counterexample: String
        /// The ``note(_:)`` messages recorded while running the counterexample.
        public var notes: [String]
        /// The choices that reproduce the counterexample.
        public var choices: ChoiceSequence
    }

    /// The number of valid examples that passed before any failure.
    public var examples: Int

    /// The seed of the run's random choices.
    public var seed: UInt64

    /// The shrunk failing example, or nil if the property held.
    public var falsification: Falsification?

    // The error `require()` throws: one Swift Testing knows was already reported.
    let requireError: (any Error)?

    /// Whether the property held for every example tried.
    public var passed: Bool { falsification == nil }

    /// Throws if the property was falsified, ending the test like a failed `#require`.
    ///
    /// The failure was already reported, so the thrown error isn't reported again.
    public func require() throws {
        if let requireError { throw requireError }
    }
}
