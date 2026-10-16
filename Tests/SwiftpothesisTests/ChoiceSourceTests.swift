import Synchronization
import Testing

@testable import Swiftpothesis

@Suite(.propertyOverrides { $0.database = nil })
struct ChoiceSourceTests {
    enum Kind: Sendable, Hashable { case transfer, sync, absorb }

    @Test func neverDrawsUnavailableChoices() async {
        let result = await forAll { test in
            let kind = try await test.draw(
                weighted: [(10, Kind.transfer), (2, .sync), (3, .absorb)],
                where: { $0 != .transfer })
            #expect(kind != .transfer)
            label("\(kind!)")
        }
        // Without transfers, sync and absorb split their weights, 2 to 3.
        #expect(result.labels["sync", default: 0] > 10)
        #expect(result.labels["absorb", default: 0] > result.labels["sync", default: 0] / 2)
    }

    @Test func checksOnlyDrawnChoices() async throws {
        let checked = Mutex<[Kind]>([])
        let testCase = TestCase(Source(prefix: [], random: nil))
        let kind = try await testCase.draw(
            weighted: [(1, Kind.transfer), (1, .sync), (1, .absorb)],
            where: { kind in
                checked.withLock { $0.append(kind) }
                return true
            })
        #expect(kind == .transfer)
        #expect(checked.withLock { $0 } == [.transfer])
    }

    @Test func shrinksTowardTheFirstAvailableChoice() async throws {
        // All-zero choices are what shrinking reaches.
        let testCase = TestCase(Source(prefix: [], random: nil))
        let kind = try await testCase.draw(
            weighted: [(5, Kind.transfer), (1, .sync), (1, .absorb)],
            where: { $0 != .transfer })
        #expect(kind == .sync)
    }

    @Test func returnsNilWhenNothingIsAvailable() async throws {
        let testCase = TestCase(Source(random: Xoshiro256(seed: 1)))
        let kind = try await testCase.draw(
            weighted: [(1, Kind.transfer), (1, .sync)], where: { _ in false })
        #expect(kind == nil)
    }
}
