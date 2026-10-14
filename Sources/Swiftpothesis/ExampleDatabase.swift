import Foundation
import Synchronization

/// Storage for failing examples, so later runs replay them before generating new ones.
///
/// The engine saves the choice sequence of each shrunk failure under a key that identifies the
/// property, and replays saved sequences in the ``Phase/reuse`` phase. Because sequences, not
/// values, are saved, an entry keeps reproducing its failure as long as the property's generators
/// draw choices the same way. An entry that stops failing is deleted.
///
/// Implementations must tolerate concurrent use from parallel tests.
public protocol ExampleDatabase: Sendable {
    /// The saved values for a key.
    func fetch(_ key: String) -> [ChoiceSequence]

    /// Saves a value under a key. Saving a value that's already saved has no effect.
    func save(_ value: ChoiceSequence, for key: String)

    /// Deletes a value saved under a key, if present.
    func delete(_ value: ChoiceSequence, for key: String)
}

/// The recorded choices of one test case, the form in which examples are replayed and persisted.
public struct ChoiceSequence: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The choices, in the order they were drawn.
    public var choices: [UInt64]

    public init(_ choices: [UInt64]) {
        self.choices = choices
    }

    public var description: String {
        choices.map(String.init).joined(separator: " ")
    }
}

/// An ``ExampleDatabase`` that keeps examples in memory, for the life of the process.
public final class InMemoryDatabase: ExampleDatabase {
    private let storage = Mutex<[String: Set<ChoiceSequence>]>([:])

    public init() {}

    public func fetch(_ key: String) -> [ChoiceSequence] {
        storage.withLock { Array($0[key] ?? []) }
    }

    public func save(_ value: ChoiceSequence, for key: String) {
        storage.withLock { _ = $0[key, default: []].insert(value) }
    }

    public func delete(_ value: ChoiceSequence, for key: String) {
        storage.withLock { _ = $0[key]?.remove(value) }
    }
}

/// An ``ExampleDatabase`` that keeps examples as files in a directory.
///
/// Each key is a subdirectory named by a hash of the key, and each value is a file in it. The
/// layout merges cleanly when the directory is shared between machines or checked into source
/// control.
public struct DirectoryDatabase: ExampleDatabase {
    /// The directory holding the database.
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The database at `$SWIFTPOTHESIS_DATABASE`, or `.swiftpothesis/examples` in the current
    /// directory, which `swift test` sets to the package root.
    public static let `default` = DirectoryDatabase(
        url: ProcessInfo.processInfo.environment["SWIFTPOTHESIS_DATABASE"].map {
            URL(filePath: $0)
        } ?? URL(filePath: ".swiftpothesis/examples"))

    public func fetch(_ key: String) -> [ChoiceSequence] {
        let directory = directory(for: key)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let choices = text.split(separator: " ").compactMap { UInt64($0) }
            return ChoiceSequence(choices)
        }
    }

    public func save(_ value: ChoiceSequence, for key: String) {
        let directory = directory(for: key)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? value.description.write(
            to: directory.appending(path: name(for: value)), atomically: true, encoding: .utf8)
    }

    public func delete(_ value: ChoiceSequence, for key: String) {
        try? FileManager.default.removeItem(
            at: directory(for: key).appending(path: name(for: value)))
    }

    private func directory(for key: String) -> URL {
        url.appending(path: stableHash(key))
    }

    private func name(for value: ChoiceSequence) -> String {
        stableHash(value.description)
    }
}

// FNV-1a, because `Hasher` is randomly seeded per process.
func stableHash(_ string: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
}
