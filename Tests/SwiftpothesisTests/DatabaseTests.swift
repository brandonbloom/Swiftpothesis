import Foundation
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
        #expect(replayed.contains { $0.contains("replayed as 501, but it was saved as 500") })
    }

    @Test func propertiesAreNumberedWithinATest() {
        let test = "DatabaseTests/\(UUID())"
        #expect(PropertyIndex.next(in: test) == 0)
        #expect(PropertyIndex.next(in: test) == 1)
        #expect(PropertyIndex.next(in: "\(test)-other") == 0)
    }
}
