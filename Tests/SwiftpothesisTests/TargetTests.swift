import Testing

@testable import Swiftpothesis

@Suite(.propertyOverrides { $0.database = nil })
struct TargetTests {
    /// Fails only when the sum is extreme, which random generation rarely reaches.
    func extremeSum(targeting: Bool, seed: UInt64) async -> PropertyResult {
        var settings = Settings.defaults
        settings.database = nil
        settings.seed = seed
        if !targeting { settings.phases.remove(.target) }
        return await failuresResult {
            await forAll(
                [Int].arbitrary(Int.arbitrary(in: 0...1000), count: 0...10), settings: settings
            ) { xs in
                let sum = xs.reduce(0, +)
                target(Double(sum), label: "sum")
                #expect(sum < 8000)
            }
        }
    }

    @Test func targetingFindsExtremeFailures() async {
        var withTargeting = 0
        var without = 0
        for seed in 1...10 as ClosedRange<UInt64> {
            if await !extremeSum(targeting: true, seed: seed).passed { withTargeting += 1 }
            if await !extremeSum(targeting: false, seed: seed).passed { without += 1 }
        }
        #expect(withTargeting > without, "with: \(withTargeting), without: \(without)")
        #expect(withTargeting >= 5)
    }

    @Test func targetScoresAreReported() async {
        let result = await forAll(Int.arbitrary(in: 0...100)) { x in
            target(Double(x), label: "x")
        }
        #expect(result.targets["x"] == 100)
    }

    @Test func labelsAreCounted() async {
        let result = await forAll(Bool.arbitrary) { b in
            label(b ? "true" : "false")
        }
        #expect(result.labels["true", default: 0] + result.labels["false", default: 0] == 100)
        #expect(result.labels["true", default: 0] > 0)
    }

    @Test(.propertyOverrides { $0.maxExamples = 10 })
    func tooMuchDataFailsAHealthCheck() async {
        let issues = await failures {
            await forAll(
                [Int].arbitrary(Int.arbitrary, count: 0...100_000, averageCount: 20_000)
            ) { _ in }
        }
        #expect(issues.contains { $0.contains("HealthCheck.dataTooLarge") })
    }
}

/// Runs `body`, which records issues if it fails, and returns the result it produced.
func failuresResult(_ body: () async -> PropertyResult) async -> PropertyResult {
    var result: PropertyResult?
    await withKnownIssue(isIntermittent: true) {
        result = await body()
    }
    return result!
}
