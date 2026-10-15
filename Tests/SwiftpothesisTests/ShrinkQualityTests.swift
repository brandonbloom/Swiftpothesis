import Testing

@testable import Swiftpothesis

/// A bug that needs three commands in order, `a` then `b` then `c`, amid unrelated ones: the
/// shape of FBF's config-sync bugs.
struct SubsequenceMachine: SequentialMachine {
    enum Command: CustomStringConvertible, Sendable {
        case a, b, c
        case noise(Int)
        var description: String {
            switch self {
            case .a: "a"
            case .b: "b"
            case .c: "c"
            case .noise(let x): "noise(\(x))"
            }
        }
    }

    func makeState() -> Int { 0 }

    func commands(for state: Int) -> some Generator<Command> {
        weighted(
            (1, constant(Command.a)), (1, constant(Command.b)), (1, constant(Command.c)),
            (6, Int.arbitrary(in: 0...100).map(Command.noise)))
    }

    func run(_ command: Command, state: inout Int) async throws {
        switch (state, command) {
        case (0, .a), (1, .b), (2, .c): state += 1
        default: break
        }
        #expect(state < 3)
    }
}

@Suite(.propertySettings { $0.database = nil })
struct ShrinkQualityTests {
    @Test(
        .propertySettings {
            $0.maxShrinkAttempts = 150
            $0.derandomize = true
        })
    func longHistoriesShrinkToTheEssentialSteps() async {
        let issues = await failures {
            await check(SubsequenceMachine(), averageSteps: 30)
        }
        let summary = issues.last ?? ""
        let steps = summary.split(separator: "\n").filter { $0.first?.isNumber == true }
        #expect(steps.map(String.init) == ["1. a", "2. b", "3. c"], "\(summary)")
    }
}
