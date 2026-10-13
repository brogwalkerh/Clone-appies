import Foundation

public struct ScanContext: Sendable {
    public let fileSystem: any FileSystem
    public let home: URL
    public let ignoreList: IgnoreList
    public let protectedPaths: ProtectedPaths
    public let isOnBattery: Bool
    public let now: Date

    public init(fileSystem: any FileSystem = LocalFileSystem(), home: URL? = nil,
                ignoreList: IgnoreList = .empty, protectedPaths: ProtectedPaths = .default,
                isOnBattery: Bool = false, now: Date = .now) {
        self.fileSystem = fileSystem
        self.home = (home ?? fileSystem.homeDirectory()).standardizedFileURL
        self.ignoreList = ignoreList
        self.protectedPaths = protectedPaths
        self.isOnBattery = isOnBattery
        self.now = now
    }
}

public protocol Scanner: Sendable {
    static var id: String { get }          // "cleanup.userCaches"
    var displayName: String { get }
    var module: ModuleID { get }
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error>
}

/// Alias for `CleanerCore.Scanner`, for files that also import Foundation
/// (whose `Foundation.Scanner` makes the bare name ambiguous).
public typealias CleanerScanner = Scanner

public extension Scanner {
    /// Instance accessor for the static identifier.
    var id: String { Self.id }
}

public enum ScanEvent: Sendable {
    case started(scannerID: String)
    case finding(Finding)
    case progress(scannerID: String, fraction: Double?)   // nil = indeterminate
    case finished(scannerID: String, count: Int, bytes: Int64)
    case failed(scannerID: String, message: String)
    case completed(ScanSummary)
}

public struct ScanSummary: Sendable, Hashable, Codable {
    public let totalFindings: Int
    public let totalBytes: Int64
    public let byCategory: [String: Int64]   // category id -> bytes
    public let duration: TimeInterval

    public init(totalFindings: Int, totalBytes: Int64, byCategory: [String: Int64], duration: TimeInterval) {
        self.totalFindings = totalFindings
        self.totalBytes = totalBytes
        self.byCategory = byCategory
        self.duration = duration
    }
}
