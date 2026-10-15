/// Something that values and primitive choices can be drawn from while a property runs.
///
/// ``TestCase`` is the choice source a running property draws from. APIs that draw on demand,
/// such as ``SequentialMachine/command(for:drawingFrom:)``, take any choice source rather than a
/// test case, so they can be exercised with a scripted source in their own tests.
public protocol ChoiceSource: Sendable {
    /// Draws a value from a generator.
    ///
    /// - Throws: ``Rejection`` when the generator rejects its choices; let it propagate, so the
    ///   test case is discarded.
    func draw<G: Generator>(_ generator: G) throws(Rejection) -> G.Value

    /// Makes a primitive choice between zero and `bound`, inclusive, where smaller is simpler.
    func choose(atMost bound: UInt64) throws(Rejection) -> UInt64
}

extension TestCase: ChoiceSource {}
