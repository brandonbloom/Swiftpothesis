extension Generator {
    /// This generator, but sometimes producing a copy, or a near copy, of a value it already
    /// produced in the same test case.
    ///
    /// Independent random values rarely collide or nearly match, so properties about equality and
    /// distinctness, such as "distinct names give distinct file names", rarely see the inputs
    /// that break them. Duplicating makes those inputs common:
    ///
    /// ```swift
    /// let names = String.arbitrary(alphabet: "aA._", count: 1...4).withDuplicates()
    /// await forAll(names, names) { a, b in
    ///     try assume(a != b)
    ///     #expect(fileName(for: a) != fileName(for: b))
    /// }
    /// ```
    ///
    /// Use one generator value for every argument that should share values: duplicates come only
    /// from values the same `withDuplicates` generator produced. A near copy replays the earlier
    /// value's choices with one nudged up or down, such as one character or one number, so it differs
    /// slightly. Copies are recorded choices like any other, so they shrink and replay; shrinking
    /// prefers fresh values.
    ///
    /// - Parameter probability: How often to produce a copy or near copy, when there's an earlier
    ///   value to copy. Half of those are exact copies and half near copies.
    public func withDuplicates(probability: Double = 0.25) -> Generators.Duplicating<Self> {
        precondition((0...1).contains(probability), "probability must be between 0 and 1")
        return Generators.Duplicating(base: self, probability: probability)
    }
}

extension Generators {
    /// A generator that sometimes repeats or varies its earlier values. See
    /// ``Generator/withDuplicates(probability:)``.
    public struct Duplicating<Base: Generator>: Generator {
        let base: Base
        let probability: Double
        // Identifies this generator's values within a test case.
        private let identity = Identity()
        private final class Identity: Sendable {}

        init(base: Base, probability: Double) {
            self.base = base
            self.probability = probability
        }

        public func generate(from source: inout Source) throws(Rejection) -> Base.Value {
            let key = ObjectIdentifier(identity)
            let earlier = source.produced[key] ?? []
            var copied: [UInt64]?
            if !earlier.isEmpty {
                // Zero, the simplest choice, means a fresh value.
                let threshold = UInt64((1 - probability) * 1000)
                let roll = try source.choose(atMost: 999, uniformly: true)
                if roll >= threshold {
                    var choices = earlier[Int(try source.choose(atMost: UInt64(earlier.count - 1)))]
                    // Odd rolls nudge one copied choice up or down by one to three, which keeps
                    // the value near: a neighboring letter of an alphabet, a nearby number.
                    if roll % 2 == 1, !choices.isEmpty {
                        let index = Int(try source.choose(atMost: UInt64(choices.count - 1)))
                        let nudge = try source.choose(atMost: 5)
                        choices[index] =
                            nudge < 3
                            ? choices[index] &+ (nudge + 1)
                            : choices[index] - Swift.min(choices[index], nudge - 2)
                    }
                    copied = choices
                }
            }
            guard let copied else {
                let start = source.choices.count
                let value = try base.generate(from: &source)
                source.produced[key, default: []].append(Array(source.choices[start...]))
                return value
            }
            // Replay the copied choices apart from the test case's own, which recorded how to
            // reconstruct them.
            var replay = Source(prefix: copied, random: nil, maxChoices: source.maxChoices)
            let value = try base.generate(from: &replay)
            source.produced[key, default: []].append(replay.choices)
            return value
        }
    }
}
