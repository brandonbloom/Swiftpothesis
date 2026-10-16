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

extension ChoiceSource {
    /// Draws one of `choices` in proportion to its weight, among those that are available,
    /// checking availability only for choices it draws.
    ///
    /// When a drawn choice isn't available, it's set aside and another is drawn from the rest, so
    /// the result is distributed as if unavailable choices had been left out of the list, without
    /// checking each one up front. That suits ``SequentialMachine/command(for:drawingFrom:)``,
    /// where checking can mean reading files:
    ///
    /// ```swift
    /// guard let kind = try await source.draw(
    ///     weighted: [(10, Kind.transfer), (2, .sync), (3, .absorb)],
    ///     where: { kind in try await world.hasOptions(kind) })
    /// else { return .syncAll }
    /// ```
    ///
    /// It's built on ``choose(atMost:)`` alone, so it shrinks toward the first available choice.
    ///
    /// - Returns: The drawn choice, or nil if none is available.
    public func draw<Choice: Sendable>(
        weighted choices: [(weight: Int, choice: Choice)],
        where isAvailable: (Choice) async throws -> Bool
    ) async throws -> Choice? {
        var remaining = choices.filter { $0.weight > 0 }
        while !remaining.isEmpty {
            let total = remaining.reduce(0) { $0 + $1.weight }
            var pick = Int(try choose(atMost: UInt64(total - 1)))
            let index = remaining.firstIndex { choice in
                defer { pick -= choice.weight }
                return pick < choice.weight
            }!
            if try await isAvailable(remaining[index].choice) { return remaining[index].choice }
            remaining.remove(at: index)
        }
        return nil
    }
}
