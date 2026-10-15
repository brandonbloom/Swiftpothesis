import Testing

/// A system under test that runs generated sequences of commands, one at a time, checking itself
/// as it goes.
///
/// A sequential state machine holds all of a test case's state in one value: the system, a model
/// of it if you have one, replicas to compare, or anything else. Each step draws a command from
/// ``commands(for:)``, which sees the current state, and ``run(_:state:)`` performs it and checks
/// the results with `#expect` or by throwing. When a sequence fails, Swiftpothesis shrinks it to
/// the fewest, simplest commands that still fail, and reports them in order.
///
/// ```swift
/// struct StackMachine: SequentialMachine {
///     enum Command: CustomStringConvertible, Sendable {
///         case push(Int), pop
///         var description: String { … }
///     }
///
///     func makeState() -> (model: [Int], stack: BoundedStack) { ([], BoundedStack(capacity: 3)) }
///
///     func commands(for state: (model: [Int], stack: BoundedStack)) -> some Generator<Command> {
///         .oneOf(Int.arbitrary(in: 0...9).map(Command.push), .constant(.pop))
///     }
///
///     func run(_ command: Command, state: inout (model: [Int], stack: BoundedStack)) async throws {
///         switch command {
///         case .push(let x):
///             state.model.append(x)
///             state.stack.push(x)
///         case .pop:
///             guard !state.model.isEmpty else { try skip("empty") }
///             #expect(state.stack.pop() == state.model.popLast())
///         }
///     }
/// }
///
/// @Test func stackBehavesLikeArray() async {
///     await check(StackMachine())
/// }
/// ```
///
/// Commands should be plain data, such as an enum, rather than closures: they must be `Sendable`,
/// and their descriptions are the failure report.
///
/// Running commands one at a time is a restriction, not just a convenience: because `run` both
/// performs and checks a command, the engine can't evaluate a command's outcome without running
/// it, so it can't check concurrent runs for linearizability. For that, see
/// ``LinearizableMachine``, which can also run sequentially.
public protocol SequentialMachine {
    /// Everything one test case needs: the system, and any model or replicas to compare it with.
    associatedtype State

    /// An operation to perform.
    associatedtype Command: CustomStringConvertible & Sendable

    /// The type of generator for commands.
    associatedtype Commands: Generator<Command>

    /// Creates the state for a fresh test case.
    func makeState() async throws -> State

    /// The commands that may run next, given the current state.
    func commands(for state: State) -> Commands

    /// Performs a command and checks its results, with `#expect`, `#require`, or by throwing.
    ///
    /// Shrinking removes earlier commands, so a command may be replayed in a state where it no
    /// longer applies, such as one naming an item that no longer exists. Call ``skip(_:)`` to
    /// skip it; skipped commands are marked in failure reports.
    func run(_ command: Command, state: inout State) async throws

    /// Checks properties that hold in every state. Runs after every command. Defaults to doing
    /// nothing.
    func checkInvariants(state: State) async throws

    /// Settles the state and checks it once, after the last command, such as checking that
    /// replicas converged. Failures here shrink like any other. Defaults to doing nothing.
    func finish(state: inout State) async throws

    /// Releases the state's resources after a test case, whether it passed or failed. Defaults to
    /// doing nothing.
    func tearDown(_ state: State) async
}

extension SequentialMachine {
    public func checkInvariants(state: State) async throws {}
    public func finish(state: inout State) async throws {}
    public func tearDown(_ state: State) async {}

    /// Skips the command being run, because it doesn't apply in the current state.
    public func skip(_ reason: String? = nil) throws -> Never {
        throw SkippedCommand(reason: reason)
    }
}

/// The error ``SequentialMachine/skip(_:)`` throws.
struct SkippedCommand: Error {
    var reason: String?
}

/// Tests a system under generated sequences of commands, one at a time.
///
/// - Parameters:
///   - machine: The system to test.
///   - steps: The allowed number of commands per test case.
///   - averageSteps: The number of commands to aim for. Some bugs need long histories; raise it
///     to find them, at the cost of slower test cases. Defaults to 20, within `steps`.
///   - id: Identifies this check within its test, so its saved failures replay. Defaults to
///     its position among the test's properties.
///   - settings: Options for this test. Defaults to the settings of the running test.
///   - sourceLocation: Where to attribute the summary issue.
///   - isolation: The actor the commands run on. Defaults to the caller's.
@discardableResult
public func check<M: SequentialMachine>(
    _ machine: M,
    steps: ClosedRange<Int> = 1...100,
    averageSteps: Double = 20,
    id: String? = nil,
    settings: Settings = .current,
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation
) async -> PropertyResult {
    await Engine(id: id, settings: settings, sourceLocation: sourceLocation).run(
        isolation: isolation
    ) {
        testCase, context in
        var state = try await machine.makeState()
        var log: [String] = []
        func show(_ line: String) {
            log.append(line)
            context.description = "\n" + log.joined(separator: "\n")
        }
        do {
            while try testCase.continues(count: log.count, bounds: steps, average: averageSteps) {
                let command = try testCase.draw(machine.commands(for: state))
                do {
                    show("\(log.count + 1). \(command)")
                    try await machine.run(command, state: &state)
                } catch let skipped as SkippedCommand {
                    log[log.count - 1] += " (skipped\(skipped.reason.map { ": \($0)" } ?? ""))"
                    context.description = "\n" + log.joined(separator: "\n")
                    continue
                }
                try await machine.checkInvariants(state: state)
            }
            show("(finish)")
            try await machine.finish(state: &state)
        } catch {
            await machine.tearDown(state)
            throw error
        }
        await machine.tearDown(state)
    }
}
