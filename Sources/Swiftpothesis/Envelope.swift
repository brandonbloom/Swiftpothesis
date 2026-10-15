import Foundation
import Testing

/// The wrapper around every JSON file Swiftpothesis writes.
///
/// Files are discardable caches, not durable data: when a file's `format` or `version` doesn't
/// match what this release writes, it's ignored with a warning rather than migrated. Versions are
/// calendar dates, bumped whenever any format changes, with a counter for later changes on the
/// same day.
///
/// ```json
/// {"format": "swiftpothesis.example", "version": "2026.10.15", "data": {…}}
/// ```
struct Envelope<Payload: Codable>: Codable {
    /// The version this release reads and writes.
    static var currentVersion: String { "2026.10.15.2" }

    /// What kind of file this is, such as `swiftpothesis.example`.
    var format: String
    /// The calendar version of the format.
    var version: String
    var data: Payload

    init(format: String, data: Payload) {
        self.format = format
        version = Self.currentVersion
        self.data = data
    }

    /// Encodes the envelope as JSON.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a payload of the given format, or returns nil with a warning if the file is in
    /// another format or version.
    static func decode(_ format: String, from data: Data, describing file: String) -> Payload? {
        guard let header = try? JSONDecoder().decode(EnvelopeHeader.self, from: data) else {
            warn("Ignoring \(file): not a Swiftpothesis file.")
            return nil
        }
        guard header.format == format, header.version == currentVersion else {
            warn(
                "Ignoring \(file): it's \(header.format) version \(header.version), but this release reads \(format) version \(currentVersion)."
            )
            return nil
        }
        guard let envelope = try? JSONDecoder().decode(Self.self, from: data) else {
            warn("Ignoring \(file): its contents don't match \(format) version \(currentVersion).")
            return nil
        }
        return envelope.data
    }

    private static func warn(_ message: String) {
        if Test.current != nil {
            Issue.record(Comment(rawValue: message), severity: .warning)
        }
    }
}

/// The fields every ``Envelope`` shares, decoded before its payload.
private struct EnvelopeHeader: Decodable {
    var format: String
    var version: String
}
