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
///
/// Following Hypothesis, structure comes first. Each round:
/// 1. Deletes runs of adjacent sibling spans, such as consecutive array elements or state-machine
///    steps, trying the largest run first and halving on failure.
/// 2. Deletes single spans, largest first, which reaches nested structure.
/// 3. Deletes and zeroes small chunks of raw choices.
/// 4. Lowers each choice to zero, raising the next to its maximum and zeroing the rest. A choice
///    often selects
///    how the next is interpreted, such as a value's kind, so lowering it alone tends to pass;
///    raising the next finds a failing value of the simpler kind, which step 5 then minimizes.
/// 5. Binary-searches each choice toward zero.
///
/// Deleting a span shifts the choices after it, so later values and steps are regenerated from
/// the remaining choices, against the new state. Rounds repeat until one makes no progress or the
/// budget runs out. Shrinking uses no randomness, so it's deterministic.
struct Shrinker {
    private(set) var choices: [UInt64]
    private(set) var spans: [Range<Int>]
    private(set) var failure: Failure
    /// The last example at each origin that shrinking moved away from.
    private(set) var leftBehind: [(choices: [UInt64], failure: Failure)] = []
    private var budget: Int
    private var pass: Pass = .deleteRuns(group: 0, start: 0, size: nil)
    private var improvedThisRound = false
    private var awaitingResult = false

    /// The outcome of running a candidate that failed: the choices it drew, the spans they
    /// formed, and its failure.
    typealias Result = (choices: [UInt64], spans: [Range<Int>], failure: Failure)

    private enum Pass {
        /// Deletes `size` siblings of `siblingGroups[group]` starting at `start`. A nil size means
        /// the largest power of two that fits.
        case deleteRuns(group: Int, start: Int, size: Int?)
        /// Deletes `spansBySize[index]`.
        case deleteSpans(index: Int)
        /// Deletes `deleteSizes[sizeIndex]` choices at `start` (nil: the last possible start),
        /// moving from the end toward the front.
        case deleteChunks(sizeIndex: Int, start: Int?)
        /// Zeroes `zeroSizes[sizeIndex]` choices at `start`, moving toward the end.
        case zero(sizeIndex: Int, start: Int)
        /// Zeroes the choice at `index` and raises the one after it to its maximum.
        case lowerAndRaiseNext(index: Int)
        /// Binary-searches the choice at `index` for its smallest failing value in `low...high`.
        case minimize(index: Int, low: UInt64, high: UInt64)
        case finished
    }

    private static let deleteSizes = [8, 4, 2, 1]
    private static let zeroSizes = [8, 4, 2]

    init(choices: [UInt64], spans: [Range<Int>], failure: Failure, budget: Int) {
        self.choices = choices
        self.spans = spans
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

    /// Records the outcome of the last candidate: its result if it failed, or nil if it didn't.
    mutating func record(_ result: Result?) {
        guard awaitingResult else { return }
        awaitingResult = false
        if let result, isSimpler(result.choices, than: choices) {
            if result.failure.origin != failure.origin,
                !leftBehind.contains(where: { $0.failure.origin == failure.origin })
            {
                leftBehind.append((choices, failure))
            }
            (choices, spans, failure) = (result.choices, result.spans, result.failure)
            improvedThisRound = true
            switch pass {
            case .minimize(let index, let low, _) where index < choices.count:
                // Keep searching below the new, smaller value.
                pass = .minimize(index: index, low: low, high: choices[index])
            case .deleteRuns, .deleteSpans:
                // Stay put: the same step now applies to different, simpler structure.
                break
            default:
                advance()
            }
        } else {
            switch pass {
            case .minimize(let index, let low, let high):
                pass = .minimize(index: index, low: low + (high - low) / 2 + 1, high: high)
            case .deleteRuns(let group, let start, let size):
                // Try a smaller run at the same start, down to one sibling.
                let size = size ?? largestRun(group: group, start: start)
                pass =
                    size > 1
                    ? .deleteRuns(group: group, start: start, size: size / 2)
                    : .deleteRuns(group: group, start: start + 1, size: nil)
            default:
                advance()
            }
        }
    }

    // MARK: - Structure

    /// Groups of sibling spans: spans with the same smallest enclosing span, in order.
    private var siblingGroups: [[Range<Int>]] {
        let unique = Array(Set(spans.filter { !$0.isEmpty }))
        var groups: [Range<Int>?: [Range<Int>]] = [:]
        for span in unique {
            let parent =
                unique
                .filter { $0 != span && $0.contains(span) }
                .min { $0.count < $1.count }
            groups[parent, default: []].append(span)
        }
        return
            groups
            .sorted {
                ($0.key?.lowerBound ?? -1, $0.key?.count ?? 0) < (
                    $1.key?.lowerBound ?? -1, $1.key?.count ?? 0
                )
            }
            .map { $0.value.sorted { $0.lowerBound < $1.lowerBound } }
    }

    /// Spans from largest to smallest, so the biggest structure goes first.
    private var spansBySize: [Range<Int>] {
        Array(Set(spans.filter { !$0.isEmpty }))
            .sorted { ($0.count, $1.lowerBound) > ($1.count, $0.lowerBound) }
    }

    private func largestRun(group: Int, start: Int) -> Int {
        let groups = siblingGroups
        guard group < groups.count else { return 0 }
        let remaining = groups[group].count - start
        guard remaining > 0 else { return 0 }
        var size = 1
        while size * 2 <= remaining { size *= 2 }
        return size
    }

    // MARK: - Candidates

    /// The candidate for the current step, or nil if the step is out of range.
    private func candidate() -> [UInt64]? {
        switch pass {
        case .deleteRuns(let group, let start, let size):
            let groups = siblingGroups
            guard group < groups.count, start < groups[group].count else { return nil }
            let size = min(
                size ?? largestRun(group: group, start: start), groups[group].count - start)
            guard size > 0 else { return nil }
            let run = groups[group][start].lowerBound..<groups[group][start + size - 1].upperBound
            var candidate = choices
            candidate.removeSubrange(run.clamped(to: 0..<choices.count))
            return candidate
        case .deleteSpans(let index):
            let spans = spansBySize
            guard index < spans.count else { return nil }
            var candidate = choices
            candidate.removeSubrange(spans[index].clamped(to: 0..<choices.count))
            return candidate
        case .deleteChunks(let sizeIndex, let start):
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
        case .lowerAndRaiseNext(let index):
            guard index + 1 < choices.count, choices[index] > 0 else { return nil }
            var candidate = choices
            candidate[index] = 0
            // Replay clamps the maximum to the next choice's bound. Later choices are zeroed:
            // under the new interpretation, their old values rarely mean anything.
            candidate[index + 1] = .max
            for later in (index + 2)..<candidate.count { candidate[later] = 0 }
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
        case .deleteRuns(let group, let start, _):
            let groups = siblingGroups
            if group < groups.count, start + 1 < groups[group].count {
                pass = .deleteRuns(group: group, start: start + 1, size: nil)
            } else if group + 1 < groups.count {
                pass = .deleteRuns(group: group + 1, start: 0, size: nil)
            } else {
                pass = .deleteSpans(index: 0)
            }
        case .deleteSpans(let index):
            pass =
                index + 1 < spansBySize.count
                ? .deleteSpans(index: index + 1) : .deleteChunks(sizeIndex: 0, start: nil)
        case .deleteChunks(let sizeIndex, let start):
            let size = Self.deleteSizes[sizeIndex]
            let next = Swift.min((start ?? choices.count - size) - 1, choices.count - size)
            if next >= 0 {
                pass = .deleteChunks(sizeIndex: sizeIndex, start: next)
            } else if sizeIndex + 1 < Self.deleteSizes.count {
                pass = .deleteChunks(sizeIndex: sizeIndex + 1, start: nil)
            } else {
                pass = .zero(sizeIndex: 0, start: 0)
            }
        case .zero(let sizeIndex, let start):
            if start + 1 + Self.zeroSizes[sizeIndex] <= choices.count {
                pass = .zero(sizeIndex: sizeIndex, start: start + 1)
            } else if sizeIndex + 1 < Self.zeroSizes.count {
                pass = .zero(sizeIndex: sizeIndex + 1, start: 0)
            } else {
                pass = .lowerAndRaiseNext(index: 0)
            }
        case .lowerAndRaiseNext(let index):
            if index + 2 < choices.count {
                pass = .lowerAndRaiseNext(index: index + 1)
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
            pass = .deleteRuns(group: 0, start: 0, size: nil)
        } else {
            pass = .finished
        }
    }
}

func isSimpler(_ a: [UInt64], than b: [UInt64]) -> Bool {
    a.count != b.count ? a.count < b.count : a.lexicographicallyPrecedes(b)
}

extension Range where Bound == Int {
    /// Whether this range contains all of `other`.
    func contains(_ other: Range<Int>) -> Bool {
        lowerBound <= other.lowerBound && other.upperBound <= upperBound
    }
}
