import Synchronization
import Testing

/// Runs `body` on `isolation`, holding back the Swift Testing issues it records instead of
/// reporting them, and returns them along with any error it throws.
///
/// Swift Testing has no direct API for this. Swift 6.2's issue-handling traits can drop issues,
/// though, and their `provideScope(for:testCase:performing:)` is public, so this applies one
/// to a block instead of a whole test.
func withIssuesCaptured(
    isolation: isolated (any Actor)?, _ body: () async throws -> Void
) async -> (issues: [Issue], error: (any Error)?) {
    guard let test = Test.current else {
        // Outside Swift Testing there are no issues to capture; only errors signal failure.
        do {
            try await body()
            return ([], nil)
        } catch {
            return ([], error)
        }
    }
    let issues = Mutex<[Issue]>([])
    let thrown = Mutex<(any Error)?>(nil)
    let trait = IssueHandlingTrait.compactMapIssues { issue in
        issues.withLock { $0.append(issue) }
        return nil
    }
    // `performing` must be @Sendable, but `body` isn't. It's safe to smuggle across: the
    // trait calls `performing` exactly once, before returning, and `body` runs back on the
    // caller's isolation.
    nonisolated(unsafe) let body = body
    do {
        try await trait.provideScope(for: test, testCase: Test.Case.current) {
            do {
                try await run(on: isolation, body)
            } catch {
                thrown.withLock { $0 = error }
            }
        }
    } catch {
        thrown.withLock { $0 = error }
    }
    return (issues.withLock { $0 }, thrown.withLock { $0 })
}

private func run(
    on isolation: isolated (any Actor)?, _ body: () async throws -> Void
) async throws {
    try await body()
}
