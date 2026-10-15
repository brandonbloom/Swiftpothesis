import Foundation
import Synchronization
import Testing

@testable import Swiftpothesis

struct DatabaseTests {
    func temporaryDatabase() -> DirectoryDatabase {
        DirectoryDatabase(
            url: FileManager.default.temporaryDirectory.appending(path: "swiftpothesis-\(UUID())"))
    }

    @Test func roundTripsThroughEnvelopes() throws {
        let database = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: database.url) }
        database.save(ChoiceSequence([1, 2, 3]), for: "key")
        #expect(database.fetch("key") == [ChoiceSequence([1, 2, 3])])

        let file = try #require(
            FileManager.default.enumerator(at: database.url, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(json.contains(#""format":"swiftpothesis.example""#))
        #expect(json.contains(#""version":"\#(Envelope<ChoiceSequence>.currentVersion)""#))
    }

    @Test func ignoresOtherVersionsWithAWarning() throws {
        let database = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: database.url) }
        database.save(ChoiceSequence([1]), for: "key")
        let file = try #require(
            FileManager.default.enumerator(at: database.url, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        let old =
            #"{"data":{"choices":[1]},"format":"swiftpothesis.example","version":"1999.01.01"}"#
        try old.write(to: file, atomically: true, encoding: .utf8)

        var fetched: [ChoiceSequence] = []
        withKnownIssue(isIntermittent: true) {
            fetched = database.fetch("key")
        } matching: { issue in
            issue.severity == .warning
        }
        #expect(fetched.isEmpty)
    }

    @Test func explicitIDsShareSavedFailuresAcrossCallSites() async {
        let database = InMemoryDatabase()
        var settings = Settings.defaults
        settings.database = database
        _ = await failures {
            await forAll(Int.arbitrary(in: 0...1000), id: "half", settings: settings) { x in
                #expect(x < 500)
            }
        }
        settings.phases = [.reuse]
        let replayed = await failures {
            await forAll(Int.arbitrary(in: 0...1000), id: "half", settings: settings) { x in
                #expect(x < 500)
            }
        }
        #expect(replayed.last?.contains("Counterexample: 500") == true)
    }

    @Test func staleReplaysAreReported() async {
        let database = InMemoryDatabase()
        var settings = Settings.defaults
        settings.database = database
        _ = await failures {
            await forAll(Int.arbitrary(in: 0...1000), id: "changed", settings: settings) { x in
                #expect(x < 500)
            }
        }
        // The same choices now produce a different value, as after reordering a weighted list.
        settings.phases = [.reuse]
        let replayed = await failures {
            await forAll(
                Int.arbitrary(in: 0...1000).map { $0 + 1 }, id: "changed", settings: settings
            ) { x in
                #expect(x < 500)
            }
        }
        #expect(replayed.contains { $0.contains("drew 501 when replayed, where it drew 500") })
        #expect(replayed.last?.contains("by a failure saved in an earlier run") == true)
    }

    @Test func replaysThatGetFurtherArentStale() async {
        // Fails at its third command until "fixed", then runs to its finish.
        struct Machine: SequentialMachine {
            let fixed: Bool
            func makeState() -> Int { 0 }
            func commands(for state: Int) -> some Generator<Int> { Int.arbitrary(in: 0...9) }
            func run(_ command: Int, state: inout Int) async throws {
                state += 1
                if !fixed { #expect(state < 3) }
            }
        }
        let database = InMemoryDatabase()
        var settings = Settings.defaults
        settings.database = database
        _ = await failures {
            await check(Machine(fixed: false), id: "machine", settings: settings)
        }
        settings.phases = [.reuse]
        let issues = Mutex<[String]>([])
        await withKnownIssue(isIntermittent: true) {
            await check(Machine(fixed: true), id: "machine", settings: settings)
        } matching: { issue in
            issues.withLock { $0.append(issue.comments.map(\.rawValue).joined()) }
            return true
        }
        #expect(!issues.withLock { $0 }.contains { $0.contains("Its generators probably changed") })
    }

    @Test func freshFailuresCountExamples() async {
        var settings = Settings.defaults
        settings.database = InMemoryDatabase()
        let issues = await failures {
            await forAll(Int.arbitrary(in: 0...1000), settings: settings) { x in #expect(x < 5) }
        }
        #expect(issues.last?.contains("Property falsified after") == true)
    }

    @Test func propertiesAreNumberedWithinATest() {
        let test = "DatabaseTests/\(UUID())"
        #expect(PropertyIndex.next(in: test) == 0)
        #expect(PropertyIndex.next(in: test) == 1)
        #expect(PropertyIndex.next(in: "\(test)-other") == 0)
    }
}
