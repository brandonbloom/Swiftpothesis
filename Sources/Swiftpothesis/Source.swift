/// The stream of choices that generators draw from.
///
/// A source either makes fresh random choices or replays choices recorded from an earlier test
/// case. Either way, it records every choice it hands out, so the engine can replay, shrink, and
/// persist a test case as a sequence of choices instead of as a value.
///
/// Most generators draw from a source only through other generators. Custom generators that need
/// primitive choices call ``choose(atMost:)``, whose result shrinks toward zero, and mark the
/// boundaries of meaningful regions with ``span(_:)`` so the shrinker can delete or reorder them as
/// units.
public struct Source: Sendable {
    // Choices recorded so far in this test case.
    var choices: [UInt64] = []
    // Regions of `choices` produced by one `span(_:)` call, in the order they closed.
    var spans: [Range<Int>] = []
    // Recorded choices replayed before any fresh ones are made.
    let prefix: [UInt64]
    // Makes fresh choices once the prefix runs out. Nil while shrinking, when the simplest choice
    // (zero) is made instead, so that deleting choices tends to delete structure.
    var random: Xoshiro256?
    // The most choices one test case may draw before it's rejected as an overrun.
    let maxChoices: Int

    init(prefix: [UInt64] = [], random: Xoshiro256?, maxChoices: Int = 8 * 1024) {
        self.prefix = prefix
        self.random = random
        self.maxChoices = maxChoices
    }

    /// Makes a primitive choice between zero and `bound`, inclusive.
    ///
    /// The shrinker simplifies a choice by making it smaller, so encode values so that smaller
    /// choices produce simpler values. For example, `Int.arbitrary(in:)` draws a sign and a
    /// magnitude rather than an offset from the range's lower bound, so integers shrink toward
    /// zero.
    ///
    /// - Throws: ``Rejection/Reason/overrun`` when the test case has drawn too many choices.
    public mutating func choose(atMost bound: UInt64) throws(Rejection) -> UInt64 {
        guard choices.count < maxChoices else { throw Rejection(.overrun) }
        let choice: UInt64
        if choices.count < prefix.count {
            choice = Swift.min(prefix[choices.count], bound)
        } else if random != nil {
            choice = random!.biasedChoice(atMost: bound)
        } else {
            choice = 0
        }
        choices.append(choice)
        return choice
    }

    /// Draws a value from another generator.
    public mutating func draw<G: Generator>(_ generator: G) throws(Rejection) -> G.Value {
        try generator.generate(from: &self)
    }

    /// Groups the choices drawn by `body` into a span.
    ///
    /// Spans tell the shrinker which runs of choices form one value, such as one element of an
    /// array, so it can delete, duplicate, or reorder them together.
    public mutating func span<T>(
        _ body: (inout Source) throws(Rejection) -> T
    ) throws(Rejection) -> T {
        let start = choices.count
        let value = try body(&self)
        spans.append(start..<choices.count)
        return value
    }
}
