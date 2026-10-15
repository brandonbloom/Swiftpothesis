import Testing

@testable import Swiftpothesis

@Suite(.propertyDefaults { $0.maxExamples *= 2 })
struct TraitTests {
    @Test func suiteTraitsApplyOncePerTest() {
        // Applied twice, the doubling would give 400.
        #expect(Settings.current.maxExamples == 200)
    }

    @Test(.propertyOverrides { $0.maxExamples += 1 })
    func overridesApplyAfterDefaults() {
        #expect(Settings.current.maxExamples == 201)
    }

    @Test(.propertyDefaults { $0.maxExamples = 5 }, .propertyOverrides { $0.maxExamples *= 3 })
    func innerTraitsApplyAfterOuterOnes() {
        // Defaults: 100 × 2, then 5. Overrides: × 3.
        #expect(Settings.current.maxExamples == 15)
    }
}
