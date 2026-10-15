import Synchronization

/// The running test case: a source of choices that the property can draw from at any point.
///
/// Values from ``forAll(_:examples:id:settings:sourceLocation:isolation:_:)``'s generators are drawn before
/// the property runs. When later values depend on what the code under test did, draw them from
/// the test case instead, while the property runs:
///
/// ```swift
/// await forAll { test in
///     let ids = try await server.create(try test.draw([String].arbitrary))
///     let victim = try test.draw(element(of: ids))
///     …
/// }
/// ```
///
/// Choices drawn this way are recorded, replayed, and shrunk like any others. Objects that make
/// choices while a test runs, such as a ``stream(of:)``, hold the test case
/// they draw from.
///
/// A test case is valid only while its property runs. Drawing from it afterward, such as from a
/// task the property didn't await, is a programming error.
public final class TestCase: Sendable {
    private let state: Mutex<Source?>

    /// The test case's virtual clock. Pass it to code under test as `some Clock<Duration>` so its
    /// sleeps and timeouts take no real time and run deterministically.
    public let clock = VirtualClock()

    init(_ source: Source) {
        state = Mutex(source)
    }

    /// Draws a value from a generator.
    ///
    /// - Throws: ``Rejection`` when the generator rejects its choices; let it propagate, so the
    ///   engine discards the test case.
    public func draw<G: Generator>(_ generator: G) throws(Rejection) -> G.Value {
        let value = try state.withLock { (source) throws(Rejection) -> G.Value in
            guard source != nil else { preconditionFailure("TestCase used after it ended") }
            // Each draw is a span, so the shrinker can delete or reorder it as a unit.
            return try source!.span { (source) throws(Rejection) in
                try generator.generate(from: &source)
            }
        }
        PropertyContext.current?.draws.append(String(reflecting: value))
        return value
    }

    /// Makes a primitive choice between zero and `bound`, inclusive. See
    /// ``Source/choose(atMost:)``.
    public func choose(atMost bound: UInt64) throws(Rejection) -> UInt64 {
        try state.withLock { (source) throws(Rejection) -> UInt64 in
            guard source != nil else { preconditionFailure("TestCase used after it ended") }
            return try source!.choose(atMost: bound)
        }
    }

    /// Draws the next element of a sequence, or nil to end it, as one span: the choice to
    /// continue, then the element. See ``Source/continues(count:bounds:average:)``.
    func drawElement<G: Generator>(
        _ generator: G, count: Int, bounds: ClosedRange<Int>, average: Double
    ) throws(Rejection) -> G.Value? {
        let value = try state.withLock { (source) throws(Rejection) -> G.Value? in
            guard source != nil else { preconditionFailure("TestCase used after it ended") }
            return try source!.span { (source) throws(Rejection) -> G.Value? in
                guard try source.continues(count: count, bounds: bounds, average: average)
                else { return nil }
                return try generator.generate(from: &source)
            }
        }
        if let value { PropertyContext.current?.draws.append(String(reflecting: value)) }
        return value
    }

    /// An endless sequence of values from a generator, each drawn when the sequence reaches it.
    ///
    /// Use streams for inputs the code under test consumes on demand, such as a stream of
    /// network responses. The sequence ends early if the test case runs out of choices.
    public func stream<G: Generator>(of generator: G) -> Stream<G> {
        Stream(testCase: self, generator: generator)
    }

    /// Ends the test case, returning its choices.
    func close() -> Source {
        state.withLock { source in
            defer { source = nil }
            return source!
        }
    }

    /// A lazy, endless sequence of generated values. See ``TestCase/stream(of:)``.
    public struct Stream<G: Generator>: Sequence, IteratorProtocol, Sendable {
        let testCase: TestCase
        let generator: G

        public mutating func next() -> G.Value? {
            try? testCase.draw(generator)
        }
    }
}
