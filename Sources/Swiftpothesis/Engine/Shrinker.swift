/// Simplifies a failing test case's choices while it keeps failing.
///
/// Any simpler candidate that fails is adopted, even if it fails at a different origin, because
/// there's no reliable way to tell whether two failures are the same bug, and a smaller failing
/// input is the better report. When shrinking moves to a new origin, the example it left behind is
/// kept in ``leftBehind``, so it can be saved and replayed later.
///
/// Candidates are ordered shortlex: fewer choices are simpler, then lexicographically smaller
/// ones. The shrinker proposes candidates one at a time with ``nextCandidate()`` and learns each
/// one's outcome from ``record(_:)``, leaving how candidates run to the ``Driver``'s caller.
/// Passes run in rounds until a round makes no progress or the budget runs out. It
/// uses no randomness, so shrinking is deterministic.
///
/// TODO: Span-aware passes (delete, duplicate, and sort spans), as Hypothesis's shrinker has.
struct Shrinker {
    private(set) var choices: [UInt64]
    private(set) var failure: Failure
    /// The last example at each origin that shrinking moved away from.
    private(set) var leftBehind: [(choices: [UInt64], failure: Failure)] = []
    private var budget: Int
    private var pass: Pass = .delete(sizeIndex: 0, start: nil)
    private var improvedThisRound = false
    private var awaitingResult = false

    private enum Pass {
        /// Deletes `deleteSizes[sizeIndex]` choices at `start` (nil: the last possible start),
        /// moving from the end toward the front.
        case delete(sizeIndex: Int, start: Int?)
        /// Zeroes `zeroSizes[sizeIndex]` choices at `start`, moving toward the end.
        case zero(sizeIndex: Int, start: Int)
        /// Binary-searches the choice at `index` for its smallest failing value in `low...high`.
        case minimize(index: Int, low: UInt64, high: UInt64)
        case finished
    }

    private static let deleteSizes = [8, 4, 2, 1]
    private static let zeroSizes = [8, 4, 2]

    init(choices: [UInt64], failure: Failure, budget: Int) {
        self.choices = choices
        self.failure = failure
        self.budget = budget
    }

    /// Whether shrinking stopped because it ran out of attempts rather than progress.
    var ranOutOfAttempts: Bool {
        if case .finished = pass { false } else { budget == 0 }
    }

    /// The next candidate to run, or nil when shrinking is done.
    mutating func nextCandidate() -> [UInt64]? {
        while budget > 0 {
            if case .finished = pass { return nil }
            guard let candidate = candidate(), isSimpler(candidate, than: choices) else {
                advance()
                continue
            }
            budget -= 1
            awaitingResult = true
            return candidate
        }
        return nil
    }

    /// Records the outcome of the last candidate: the choices it drew and its failure, or nil if
    /// it didn't fail.
    mutating func record(_ result: (choices: [UInt64], failure: Failure)?) {
        guard awaitingResult else { return }
        awaitingResult = false
        if let result, isSimpler(result.choices, than: choices) {
            if result.failure.origin != failure.origin,
                !leftBehind.contains(where: { $0.failure.origin == failure.origin })
            {
                leftBehind.append((choices, failure))
            }
            (choices, failure) = (result.choices, result.failure)
            improvedThisRound = true
            if case .minimize(let index, let low, _) = pass, index < choices.count {
                // Keep searching below the new, smaller value.
                pass = .minimize(index: index, low: low, high: choices[index])
            } else {
                advance()
            }
        } else if case .minimize(let index, let low, let high) = pass {
            pass = .minimize(index: index, low: low + (high - low) / 2 + 1, high: high)
        } else {
            advance()
        }
    }

    /// The candidate for the current step, or nil if the step is out of range.
    private func candidate() -> [UInt64]? {
        switch pass {
        case .delete(let sizeIndex, let start):
            let size = Self.deleteSizes[sizeIndex]
            let start = start ?? choices.count - size
            guard start >= 0, start + size <= choices.count else { return nil }
            var candidate = choices
            candidate.removeSubrange(start..<start + size)
            return candidate
        case .zero(let sizeIndex, let start):
            let size = Self.zeroSizes[sizeIndex]
            guard start + size <= choices.count else { return nil }
            var candidate = choices
            for i in start..<start + size { candidate[i] = 0 }
            return candidate
        case .minimize(let index, let low, let high):
            guard index < choices.count, low < high else { return nil }
            var candidate = choices
            candidate[index] = low + (high - low) / 2
            return candidate
        case .finished:
            return nil
        }
    }

    /// Moves to the next step, the next pass, or the next round.
    private mutating func advance() {
        switch pass {
        case .delete(let sizeIndex, let start):
            let size = Self.deleteSizes[sizeIndex]
            let next = Swift.min((start ?? choices.count - size) - 1, choices.count - size)
            if next >= 0 {
                pass = .delete(sizeIndex: sizeIndex, start: next)
            } else if sizeIndex + 1 < Self.deleteSizes.count {
                pass = .delete(sizeIndex: sizeIndex + 1, start: nil)
            } else {
                pass = .zero(sizeIndex: 0, start: 0)
            }
        case .zero(let sizeIndex, let start):
            if start + 1 + Self.zeroSizes[sizeIndex] <= choices.count {
                pass = .zero(sizeIndex: sizeIndex, start: start + 1)
            } else if sizeIndex + 1 < Self.zeroSizes.count {
                pass = .zero(sizeIndex: sizeIndex + 1, start: 0)
            } else {
                startMinimizing(at: 0)
            }
        case .minimize(let index, _, _):
            startMinimizing(at: index + 1)
        case .finished:
            break
        }
    }

    private mutating func startMinimizing(at index: Int) {
        if index < choices.count {
            pass = .minimize(index: index, low: 0, high: choices[index])
        } else if improvedThisRound {
            // A round that made progress earns another.
            improvedThisRound = false
            pass = .delete(sizeIndex: 0, start: nil)
        } else {
            pass = .finished
        }
    }
}

func isSimpler(_ a: [UInt64], than b: [UInt64]) -> Bool {
    a.count != b.count ? a.count < b.count : a.lexicographicallyPrecedes(b)
}
