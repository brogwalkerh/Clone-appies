import Foundation
import CleanerCore

public enum ScanScope: String, Codable, Sendable, CaseIterable {
    case quick, normal, deep

    /// True when this scope covers everything `other` covers.
    func includes(_ other: ScanScope) -> Bool {
        rank >= other.rank
    }

    private var rank: Int {
        switch self {
        case .quick: 0
        case .normal: 1
        case .deep: 2
        }
    }
}

public enum ThreatSeverity: String, Codable, Sendable, Comparable, CaseIterable {
    case low, medium, high, critical

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        }
    }

    public static func < (lhs: ThreatSeverity, rhs: ThreatSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum ThreatKind: String, Codable, Sendable {
    case signature, heuristic
}

public struct Threat: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let path: URL
    /// "Eicar-Test-Signature", "Heuristic.UnsignedLaunchAgent", ...
    public let name: String
    public let kind: ThreatKind
    public let severity: ThreatSeverity
    public let detail: String
    public let sizeBytes: Int64
    public let isDirectory: Bool

    public init(id: UUID = UUID(), path: URL, name: String, kind: ThreatKind, severity: ThreatSeverity,
                detail: String, sizeBytes: Int64, isDirectory: Bool = false) {
        self.id = id
        self.path = path.standardizedFileURL
        self.name = name
        self.kind = kind
        self.severity = severity
        self.detail = detail
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
    }

    /// The same item as a `Finding` for the shared scan/removal pipeline:
    /// category "protection.malware", risk `.safe`, detail "<name>: <detail>".
    /// The finding reuses the threat's `id`.
    public var finding: Finding {
        Finding(id: id, path: path, sizeBytes: sizeBytes, category: ProtectionCategory.malware,
                scannerID: MalwareScanner.id, risk: .safe, detail: "\(name): \(detail)",
                modifiedAt: nil, isDirectory: isDirectory)
    }
}

/// Categories shared by the Protection scanners.
enum ProtectionCategory {
    static let malware = FindingCategory(id: "protection.malware", displayName: "Malware", module: .protection)

    static func privacy(_ kind: String, _ displayName: String) -> FindingCategory {
        FindingCategory(id: "privacy.\(kind)", displayName: displayName, module: .protection)
    }
}
