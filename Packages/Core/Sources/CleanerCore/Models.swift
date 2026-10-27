import Foundation

public enum ModuleID: String, Codable, Sendable, CaseIterable, Hashable {
    case cleanup, protection, performance, applications, clutter
}

public enum RiskLevel: String, Codable, Sendable, Hashable, Comparable {
    case safe      // selected by default, no user data lost
    case caution   // selected by default but called out (e.g. app caches that force re-login)
    case risky     // never selected by default (e.g. language files, system caches)

    private var rank: Int {
        switch self {
        case .safe: 0
        case .caution: 1
        case .risky: 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct FindingCategory: Hashable, Codable, Sendable {
    public let id: String            // e.g. "cleanup.userCaches"
    public let displayName: String   // e.g. "User Cache Files"
    public let module: ModuleID

    public init(id: String, displayName: String, module: ModuleID) {
        self.id = id
        self.displayName = displayName
        self.module = module
    }
}

public struct Finding: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let path: URL
    public let sizeBytes: Int64
    public let category: FindingCategory
    public let scannerID: String
    public let risk: RiskLevel
    public let detail: String?           // one line shown under the path
    public let modifiedAt: Date?
    public let isDirectory: Bool

    public init(id: UUID = UUID(), path: URL, sizeBytes: Int64, category: FindingCategory,
                scannerID: String, risk: RiskLevel, detail: String? = nil,
                modifiedAt: Date? = nil, isDirectory: Bool = false) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.category = category
        self.scannerID = scannerID
        self.risk = risk
        self.detail = detail
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }
}
