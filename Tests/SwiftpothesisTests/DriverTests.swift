import Testing

@testable import Swiftpothesis

struct DriverTests {
    struct BugA: Error {}
    struct BugB: Error {}

    /// Runs a property of one integer through the driver, without Swift Testing in the loop.
    func run(_ driver: inout Driver, _ property: (Int) -> (any Error)?) {
        while let source = driver.next() {
            let testCase = TestCase(source)
            let error = (try? testCase.draw(Int.arbitrary(in: 0...1000))).flatMap(property)
            driver.record(
                error.map { .failed(Failure(issues: [], error: $0)) } ?? .passed,
                source: testCase.close())
        }
    }

    @Test func shrinkingMovesToSimplerFailureAndSavesTheOriginal() {
        let database = InMemoryDatabase()
        database.save(ChoiceSequence([700]), for: "key")
        var settings = Settings.defaults
        settings.database = database
        settings.phases = [.reuse, .shrink]
        var driver = Driver(settings: settings, databaseKey: "key", seedKey: "key")

        // Bug A fails for 10 and up; bug B fails only for 0, which is simpler.
        run(&driver) { x in x == 0 ? BugB() : x >= 10 ? BugA() : nil }

        #expect(driver.original?.failure.origin == "a thrown BugA")
        #expect(driver.found?.failure.origin == "a thrown BugB")
        #expect(driver.found?.choices == [0])
        // The driver saves the example it left behind; the engine saves the shrunk one, once it
        // knows how to describe it.
        let saved = Set(database.fetch("key").map(\.choices))
        #expect(saved.contains { $0.count == 1 && $0[0] >= 10 })
    }
}
