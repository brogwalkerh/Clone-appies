# Shared interface contracts

Every package and target codes against these types. They live in
`Packages/Core` (module name `CleanerCore`). Do not change a signature here
without updating this file and every dependent in the same change.

## Conventions
- Swift 6.2, `swift-tools-version: 6.0`, strict concurrency (`-strict-concurrency=complete`).
- Foundation-only in `CleanerCore`, `CleanupModule`, `SpaceLens`, `CLI`. These must
  build and pass `swift test` on Linux (Ubuntu 24.04) and macOS.
- Anything importing AppKit / SwiftUI / Vision / ServiceManagement lives in `App/`,
  `MenuAgent/`, `Packages/DesignSystem`, `Packages/UIKitBridge` and is guarded with
  `#if canImport(AppKit)` only when shared code must touch it.
- Public types are `Sendable`. Models are `Codable` + `Hashable`.
- Sizes are `Int64` bytes. Paths are `URL` (file URLs, standardized).

## CleanerCore

```swift
public enum ModuleID: String, Codable, Sendable, CaseIterable, Hashable {
    case cleanup, protection, performance, applications, clutter
}

public enum RiskLevel: String, Codable, Sendable, Hashable, Comparable {
    case safe      // selected by default, no user data lost
    case caution   // selected by default but called out (e.g. app caches that force re-login)
    case risky     // never selected by default (e.g. language files, system caches)
}

public struct FindingCategory: Hashable, Codable, Sendable {
    public let id: String            // e.g. "cleanup.userCaches"
    public let displayName: String   // e.g. "User Cache Files"
    public let module: ModuleID
    public init(id: String, displayName: String, module: ModuleID)
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
                modifiedAt: Date? = nil, isDirectory: Bool = false)
}

/// Abstracts the filesystem so scanners can be tested against fixtures.
public protocol FileSystem: Sendable {
    func exists(_ url: URL) -> Bool
    func attributes(of url: URL) throws -> FileAttributes
    func children(of url: URL) throws -> [URL]           // non-recursive, no hidden filtering
    func contents(of url: URL) throws -> Data           // for small files (plists, rules)
    func homeDirectory() -> URL
    func temporaryDirectory() -> URL
}
public struct FileAttributes: Sendable, Hashable {
    public let sizeBytes: Int64         // allocated size for files, 0 for directories
    public let modifiedAt: Date?
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isPackage: Bool          // macOS bundle; always false on Linux
}
public struct LocalFileSystem: FileSystem { public init() }

public struct ScanContext: Sendable {
    public let fileSystem: any FileSystem
    public let home: URL
    public let ignoreList: IgnoreList
    public let protectedPaths: ProtectedPaths
    public let isOnBattery: Bool
    public let now: Date
    public init(fileSystem: any FileSystem = LocalFileSystem(), home: URL? = nil,
                ignoreList: IgnoreList = .empty, protectedPaths: ProtectedPaths = .default,
                isOnBattery: Bool = false, now: Date = .now)
}

public protocol Scanner: Sendable {
    static var id: String { get }          // "cleanup.userCaches"
    var displayName: String { get }
    var module: ModuleID { get }
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error>
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
}

public actor ScanCoordinator {
    public init(scanners: [any Scanner], maxConcurrency: Int = 4)
    /// Runs all scanners concurrently, de-duplicates findings by standardized path,
    /// drops any finding under a protected path or matching the ignore list, and
    /// yields events. Finishes with `.completed`.
    public func run(_ context: ScanContext) -> AsyncStream<ScanEvent>
    public func cancel()
}

public struct ProtectedPaths: Sendable, Hashable, Codable {
    public static let `default`: ProtectedPaths   // /System, /usr, /bin, /sbin, /private/var/db, /Library/Apple, Time Machine mounts, app's own containers
    public init(prefixes: [URL])
    public func isProtected(_ url: URL) -> Bool
}

public struct IgnoreList: Sendable, Hashable, Codable {
    public static let empty: IgnoreList
    public init(paths: Set<URL> = [], globs: [String] = [])
    public func contains(_ url: URL) -> Bool
    public func adding(_ url: URL) -> IgnoreList
}

public enum RemovalMode: String, Codable, Sendable { case trash, permanent }

public struct RemovalRecord: Codable, Sendable, Hashable {
    public let finding: Finding
    public let trashedTo: URL?        // nil for permanent
    public let succeeded: Bool
    public let error: String?
}
public struct RemovalManifest: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let mode: RemovalMode
    public let records: [RemovalRecord]
    public var bytesReclaimed: Int64 { get }
}

public protocol Remover: Sendable {
    func remove(_ findings: [Finding], mode: RemovalMode,
                progress: (@Sendable (Int, Int) -> Void)?) async throws -> RemovalManifest
    func undo(_ manifest: RemovalManifest) async throws -> [RemovalRecord]  // best-effort restore from Trash
}
/// macOS: FileManager.trashItem. Linux: moves into XDG trash dir (~/.local/share/Trash/files) for test parity.
public struct TrashRemover: Remover { public init(fileSystem: any FileSystem = LocalFileSystem()) }

/// Refuses to remove anything under ProtectedPaths; wraps another Remover.
public struct GuardedRemover: Remover { public init(wrapping: any Remover, protectedPaths: ProtectedPaths) }

/// Recursive directory walker used by scanners.
public struct FileWalker: Sendable {
    public init(fileSystem: any FileSystem, followsSymlinks: Bool = false, skipsPackageContents: Bool = true)
    public func walk(_ root: URL, maxDepth: Int? = nil) -> AsyncThrowingStream<(URL, FileAttributes), any Error>
    public func directorySize(_ root: URL) async throws -> Int64
}

public enum ByteFormatter {
    public static func string(_ bytes: Int64) -> String   // "12.4 GB", binary-free decimal, 1 decimal place
}
```

## CleanupModule (Packages/Modules/Cleanup)

```swift
public enum CleanupScanners {
    public static func all() -> [any Scanner]      // in display order
}
/// Rules table loaded from Resources/cleanup-rules.json: known cache/log dirs with
/// risk level, human description (Smart Insights fallback), and glob patterns.
public struct CleanupRule: Codable, Sendable, Hashable {
    public let id: String; public let category: String; public let relativePaths: [String]  // relative to home or "/"
    public let risk: RiskLevel; public let description: String
}
```

## SpaceLens (Packages/SpaceLens)

```swift
public struct SizeNode: Sendable, Hashable, Identifiable {
    public let id: URL; public let name: String; public let sizeBytes: Int64
    public let isDirectory: Bool; public var children: [SizeNode]
}
public struct Bubble: Sendable, Hashable, Identifiable {
    public let id: URL; public let center: CGPoint; public let radius: Double; public let depth: Int; public let node: SizeNode
}
public struct CirclePackingLayout: Sendable {
    public init(padding: Double = 2, minRadius: Double = 3)
    /// Lays out `node.children` inside a circle of `radius` centered at `center`.
    public func layout(_ node: SizeNode, in radius: Double, center: CGPoint, maxDepth: Int = 2) -> [Bubble]
}
public struct SizeTreeBuilder: Sendable {
    public init(fileSystem: any FileSystem)
    public func build(root: URL, maxDepth: Int = 3) async throws -> SizeNode
}
```
On Linux `CGPoint` comes from Foundation; keep it or define `Point` typealias in SpaceLens.

## CLI (CLI/)
Executable `maccleaner`: `scan [--module cleanup|...] [--json] [--home PATH]`,
`list-scanners`, `remove --manifest-out PATH --dry-run`. Depends on swift-argument-parser.

## App (App/) — SwiftUI, macOS 27 only
Depends on CleanerCore, CleanupModule, SpaceLens, DesignSystem. `ScanViewModel`
(`@MainActor @Observable`) consumes `ScanCoordinator.run` events.

## Implementation notes (CleanerCore as built)
- `Scanner` collides with `Foundation.Scanner` in files importing both. Write
  `CleanerCore.Scanner` or use the alias `CleanerScanner`.
- `FileWalker.walk` does not yield the root; depth 1 is the root's direct children.
  Unreadable subdirectories are skipped; only an unreadable root throws.
- `IgnoreList.contains` treats listed paths as covering their descendants. A glob
  without `/` also matches the last path component.
- A cancelled coordinator run emits `.finished` with partial counts for the
  interrupted scanner, then `.completed`.
- Extra public inits exist on `FileAttributes`, `ScanSummary`, `RemovalRecord`,
  `RemovalManifest`; `TrashRemover(fileSystem:trashDirectory:)` forces move-based
  trash on every platform (for tests). `CleanerCoreTesting` ships `MockFileSystem`
  (dictionary-literal trees) and `FixtureBuilder` (real temp trees).
