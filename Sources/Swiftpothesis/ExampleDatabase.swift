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
/// Each key is a subdirectory named by a hash of the key, and each value is a JSON file in it,
/// in an envelope that identifies its format and version. Files from another version are ignored
/// with a warning: the database is a cache, safe to delete at any time.
public struct DirectoryDatabase: ExampleDatabase {
    /// The directory holding the database.
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The database at `$SWIFTPOTHESIS_DATABASE`, or else in the user's cache directory:
    /// `~/Library/Caches/Swiftpothesis/examples` on Apple platforms, and under `$XDG_CACHE_HOME`
    /// or `~/.cache` on Linux.
    ///
    /// Tests on a simulator or device use that platform's cache directory, so their failures are
    /// saved apart from the Mac's.
    public static let `default` = DirectoryDatabase(
        url: ProcessInfo.processInfo.environment["SWIFTPOTHESIS_DATABASE"].map {
            URL(filePath: $0)
        } ?? URL.cachesDirectory.appending(path: "Swiftpothesis/examples"))

    public func fetch(_ key: String) -> [ChoiceSequence] {
        let directory = directory(for: key)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return Envelope<ChoiceSequence>.decode(
                Self.format, from: data, describing: file.path(percentEncoded: false))
        }
    }

    public func save(_ value: ChoiceSequence, for key: String) {
        let directory = directory(for: key)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Envelope(format: Self.format, data: value).encoded() else { return }
        try? data.write(to: directory.appending(path: name(for: value)), options: .atomic)
    }

    public func delete(_ value: ChoiceSequence, for key: String) {
        try? FileManager.default.removeItem(
            at: directory(for: key).appending(path: name(for: value)))
    }

    private func directory(for key: String) -> URL {
        url.appending(path: stableHash(key))
    }

    private func name(for value: ChoiceSequence) -> String {
        stableHash(value.description) + ".json"
    }

    private static let format = "swiftpothesis.example"
}

// FNV-1a, because `Hasher` is randomly seeded per process.
func stableHash(_ string: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
}
