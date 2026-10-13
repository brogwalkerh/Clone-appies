import Foundation
import CleanerCore

/// The JSON document `maccleaner scan --json` prints and `maccleaner remove
/// --from-json` reads: `{ "summary": ScanSummary, "findings": [Finding] }`.
struct ScanDocument: Codable, Hashable, Sendable {
    let summary: ScanSummary
    let findings: [Finding]

    init(summary: ScanSummary, findings: [Finding]) {
        self.summary = summary
        self.findings = findings
    }

    /// Builds a document whose summary is consistent with `findings` (used after
    /// filtering, so counts and bytes always describe the listed findings).
    init(findings: [Finding], duration: TimeInterval) {
        var byCategory: [String: Int64] = [:]
        var total: Int64 = 0
        for finding in findings {
            byCategory[finding.category.id, default: 0] += finding.sizeBytes
            total += finding.sizeBytes
        }
        self.summary = ScanSummary(totalFindings: findings.count, totalBytes: total,
                                   byCategory: byCategory, duration: duration)
        self.findings = findings
    }
}

/// JSON coding shared by every command: ISO 8601 dates, pretty-printed, sorted keys.
enum ScanJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode(_ value: some Encodable) throws -> String {
        let data = try encoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decode(type, from: data)
    }

    /// Writes `value` as JSON, creating intermediate directories.
    static func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try encoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}

/// Deterministic ordering for output: largest first, then by path.
extension Array where Element == Finding {
    func sortedBySize() -> [Finding] {
        sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            return lhs.path.path < rhs.path.path
        }
    }
}

extension RiskLevel {
    /// Fixed-width badge used in tables and removal listings.
    var badge: String {
        switch self {
        case .safe: return "[safe]   "
        case .caution: return "[caution]"
        case .risky: return "[RISKY]  "
        }
    }
}
