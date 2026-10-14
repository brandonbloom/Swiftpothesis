/// Simplifies a failing test case's choices while it keeps failing the same way.
///
/// Candidates are ordered shortlex: fewer choices are simpler, then lexicographically smaller
/// ones. Each pass proposes simpler candidates and keeps any that still fail with the same
/// ``Failure/signature``, until no pass makes progress or the budget runs out.
///
/// TODO: Span-aware passes (delete, duplicate, and sort spans), as Hypothesis's shrinker has.
struct Shrinker {
    private(set) var choices: [UInt64]
    private(set) var failure: Failure
    private var budget: Int

    init(choices: [UInt64], failure: Failure, budget: Int) {
        self.choices = choices
        self.failure = failure
        self.budget = budget
    }

    /// Runs a candidate, returning the choices it actually drew and its failure, or nil if it
    /// didn't fail.
    typealias Attempt =
        nonisolated(nonsending) ([UInt64]) async -> (choices: [UInt64], failure: Failure)?

    nonisolated(nonsending) mutating func shrink(_ attempt: Attempt) async -> ([UInt64], Failure) {
        var improved = true
        while improved, budget > 0 {
            improved = false
            improved = await deleteChunks(attempt) || improved
            improved = await zeroChunks(attempt) || improved
            improved = await minimizeEach(attempt) || improved
        }
        return (choices, failure)
    }

    /// Tries a candidate, adopting it if it's simpler and fails the same way.
    nonisolated(nonsending) private mutating func consider(
        _ candidate: [UInt64], _ attempt: Attempt
    ) async -> Bool {
        guard budget > 0, isSimpler(candidate, than: choices) else { return false }
        budget -= 1
        guard let result = await attempt(candidate),
            result.failure.signature == failure.signature,
            isSimpler(result.choices, than: choices)
        else { return false }
        (choices, failure) = (result.choices, result.failure)
        return true
    }

    nonisolated(nonsending) private mutating func deleteChunks(_ attempt: Attempt) async -> Bool {
        var improved = false
        for size in [8, 4, 2, 1] {
            var start = choices.count - size
            while start >= 0 {
                var candidate = choices
                candidate.removeSubrange(start..<Swift.min(start + size, candidate.count))
                if await consider(candidate, attempt) { improved = true }
                start -= 1
                start = Swift.min(start, choices.count - size)
            }
        }
        return improved
    }

    nonisolated(nonsending) private mutating func zeroChunks(_ attempt: Attempt) async -> Bool {
        var improved = false
        for size in [8, 4, 2] {
            var start = 0
            while start + size <= choices.count {
                var candidate = choices
                for i in start..<start + size { candidate[i] = 0 }
                if await consider(candidate, attempt) { improved = true }
                start += 1
            }
        }
        return improved
    }

    /// Binary-searches each choice down toward zero.
    nonisolated(nonsending) private mutating func minimizeEach(_ attempt: Attempt) async -> Bool {
        var improved = false
        var index = 0
        while index < choices.count {
            var low: UInt64 = 0
            var high = choices[index]
            while low < high, budget > 0 {
                let mid = low + (high - low) / 2
                var candidate = choices
                candidate[index] = mid
                if await consider(candidate, attempt) {
                    improved = true
                    high = index < choices.count ? choices[index] : 0
                } else {
                    low = mid + 1
                }
            }
            index += 1
        }
        return improved
    }
}

func isSimpler(_ a: [UInt64], than b: [UInt64]) -> Bool {
    a.count != b.count ? a.count < b.count : a.lexicographicallyPrecedes(b)
}
