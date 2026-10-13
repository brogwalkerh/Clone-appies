import Foundation

public enum RemovalMode: String, Codable, Sendable { case trash, permanent }

public struct RemovalRecord: Codable, Sendable, Hashable {
    public let finding: Finding
    public let trashedTo: URL?        // nil for permanent
    public let succeeded: Bool
    public let error: String?

    public init(finding: Finding, trashedTo: URL?, succeeded: Bool, error: String?) {
        self.finding = finding
        self.trashedTo = trashedTo
        self.succeeded = succeeded
        self.error = error
    }
}

public struct RemovalManifest: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let mode: RemovalMode
    public let records: [RemovalRecord]

    public var bytesReclaimed: Int64 {
        records.reduce(into: Int64(0)) { total, record in
            if record.succeeded { total += record.finding.sizeBytes }
        }
    }

    public init(id: UUID = UUID(), startedAt: Date = .now, mode: RemovalMode, records: [RemovalRecord]) {
        self.id = id
        self.startedAt = startedAt
        self.mode = mode
        self.records = records
    }
}

public enum RemovalError: Error, Sendable, Hashable {
    /// A finding lives under a protected path; nothing was removed.
    case protectedPath(URL)
    case notFound(URL)
    case destinationExists(URL)
    case trashUnavailable(String)
    case failed(URL, String)
}

extension RemovalError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .protectedPath(let url): "protected path: \(url.path)"
        case .notFound(let url): "not found: \(url.path)"
        case .destinationExists(let url): "destination already exists: \(url.path)"
        case .trashUnavailable(let reason): "trash unavailable: \(reason)"
        case .failed(let url, let reason): "\(url.path): \(reason)"
        }
    }
}

public protocol Remover: Sendable {
    func remove(_ findings: [Finding], mode: RemovalMode,
                progress: (@Sendable (Int, Int) -> Void)?) async throws -> RemovalManifest
    func undo(_ manifest: RemovalManifest) async throws -> [RemovalRecord]  // best-effort restore from Trash
}
