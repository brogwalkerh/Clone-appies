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
    public let sizeBytes: Int64         // allocated (on-disk) size for files, 0 for directories
    public let logicalSizeBytes: Int64  // byte length of the contents (st_size); == sizeBytes on Linux
    public let modifiedAt: Date?
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isPackage: Bool          // macOS bundle; always false on Linux
    public init(sizeBytes: Int64, logicalSizeBytes: Int64? = nil /* defaults to sizeBytes */,
                modifiedAt: Date? = nil, isDirectory: Bool = false, isSymlink: Bool = false,
                isPackage: Bool = false)
}
// `sizeBytes` (Darwin: totalFileAllocatedSizeKey) is what reclaim figures and
// `Finding.sizeBytes` report. `logicalSizeBytes` (Darwin: fileSizeKey) is what
// content comparison must use: APFS compression and clonefile make byte-identical
// files report different allocated sizes. `MockFileSystem` nodes take an optional
// `allocatedSize:` to model this.
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

## M2 — ClutterModule (Packages/Modules/Clutter)

Foundation-only. Module `ClutterModule`, depends on CleanerCore.

```swift
public enum ClutterScanners {
    public static func all(imageFeatures: (any ImageFeatureProvider)? = nil) -> [any CleanerScanner]
}

/// Large & Old: files >= minSize or not modified in >= minAge under the user's
/// home (Documents, Desktop, Downloads, Movies, Music, Pictures by default).
public struct LargeOldFilesScanner: CleanerScanner {   // id "clutter.largeOld"
    public init(minSizeBytes: Int64 = 100_000_000, minAge: TimeInterval = 180 * 86_400,
                roots: [String] = ["Documents","Desktop","Downloads","Movies","Music","Pictures"])
}
/// Duplicates: size bucket -> head+tail FNV-1a 64 -> full streaming SHA-256
/// (pure Swift, in-package) -> group. Each duplicate group's *keeper* is the
/// oldest file; the others are emitted as findings with category
/// "clutter.duplicates", detail "Duplicate of <keeper path>", risk .caution.
public struct DuplicatesScanner: CleanerScanner {       // id "clutter.duplicates"
    public init(minSizeBytes: Int64 = 1_024, roots: [String] = [...same as above...])
}
public struct SHA256 { public static func hash(_ data: Data) -> [UInt8]; public static func hexString(_ digest: [UInt8]) -> String }
public struct StreamingSHA256 { public init(); public mutating func update(_ data: Data); public mutating func finalize() -> [UInt8] }

/// Similar images: platform-neutral. Feature extraction is injected; the
/// macOS implementation (Vision VNGenerateImageFeaturePrintRequest) lives in
/// Packages/UIKitBridge. On Linux tests use a stub provider.
public protocol ImageFeatureProvider: Sendable {
    func featurePrint(for url: URL) async throws -> [Float]?   // nil = not an image / unsupported
}
public struct SimilarImagesScanner: CleanerScanner {    // id "clutter.similarImages"
    public init(provider: any ImageFeatureProvider, threshold: Float = 0.25, roots: [String] = ["Pictures","Desktop","Downloads"])
    // Clusters by cosine distance <= threshold; keeper = largest file; others emitted,
    // detail "Similar to <keeper>", risk .caution, category "clutter.similarImages".
}
/// Downloads triage: category "clutter.downloads"; installers (.dmg/.pkg/.zip), screenshots
/// ("Screenshot*.png", "Screen Recording*.mov"), and anything older than 90 days. Risk .caution.
public struct DownloadsScanner: CleanerScanner { public init(staleAfter: TimeInterval = 90 * 86_400) }  // id "clutter.downloads"
```

## M2 — ApplicationsModule (Packages/Modules/Applications)

Foundation-only. Module `ApplicationsModule`, depends on CleanerCore.

```swift
public struct InstalledApp: Sendable, Hashable, Codable, Identifiable {
    public var id: URL { bundleURL }
    public let bundleURL: URL
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?            // CFBundleShortVersionString
    public let build: String?              // CFBundleVersion
    public let source: AppSource           // .appStore, .direct, .homebrewCask, .setapp, .system, .unknown
    public let sizeBytes: Int64
    public let lastOpened: Date?
    public let sparkleFeedURL: URL?        // SUFeedURL from Info.plist
}
public enum AppSource: String, Codable, Sendable, Hashable { case appStore, direct, homebrewCask, setapp, system, unknown }

/// Discovers apps in /Applications, /Applications/Utilities, ~/Applications,
/// /Applications/Setapp, Homebrew cask dirs (/opt/homebrew/Caskroom, /usr/local/Caskroom).
/// Reads Info.plist via PropertyListDecoder. Source heuristics: _MASReceipt/receipt => appStore;
/// Caskroom symlink target => homebrewCask; /Applications/Setapp => setapp; /System/Applications
/// and apps whose bundle id starts with com.apple. => system; else direct.
public struct AppInventory: Sendable {
    public init(fileSystem: any FileSystem)
    public func discover(home: URL) async throws -> [InstalledApp]
}

/// Leftover locations for a bundle id, relative to home:
/// Library/Application Support/<bid|name>, Library/Caches/<bid>, Library/Preferences/<bid>.plist,
/// Library/Containers/<bid>, Library/Group Containers/*<bid>*, Library/Saved Application State/<bid>.savedState,
/// Library/LaunchAgents/<bid>*.plist, Library/Logs/<bid|name>, Library/HTTPStorages/<bid>,
/// Library/WebKit/<bid>, Library/Application Scripts/<bid>, Library/Cookies/<bid>.binarycookies.
public struct LeftoverResolver: Sendable {
    public init(fileSystem: any FileSystem)
    public func leftovers(for app: InstalledApp, home: URL) async -> [Finding]   // category "applications.leftovers", risk .safe, detail "<app name> support file"
}

public enum ApplicationsScanners {
    public static func all() -> [any CleanerScanner]
}
/// id "applications.orphanedLeftovers": leftover dirs/plists in the locations above whose
/// bundle id matches NO installed app and is not com.apple.* => risk .safe, category "applications.orphaned".
public struct OrphanedLeftoversScanner: CleanerScanner { public init() }
/// id "applications.installers": *.dmg, *.pkg, *.mpkg in Downloads, Desktop, Documents => category "applications.installers", risk .caution.
public struct InstallersScanner: CleanerScanner { public init() }

/// Update checking. Network via URLSession; parsing via FoundationXML on Linux (#if canImport(FoundationXML)).
public struct AvailableUpdate: Sendable, Hashable, Codable { public let app: InstalledApp; public let latestVersion: String; public let downloadURL: URL?; public let releaseNotesURL: URL?; public let source: AppSource }
public protocol UpdateSource: Sendable { func check(_ apps: [InstalledApp]) async -> [AvailableUpdate] }
public struct SparkleUpdateSource: UpdateSource { public init(session: URLSession = .shared) }  // fetches SUFeedURL appcasts, compares versions with VersionComparator
public struct VersionComparator { public static func compare(_ a: String, _ b: String) -> ComparisonResult }  // numeric dotted, handles "1.2.3 (456)", "2.0b1"
public actor UpdateChecker { public init(sources: [any UpdateSource]); public func check(_ apps: [InstalledApp]) async -> [AvailableUpdate] }
```
App Store and Homebrew update sources are macOS-only and live in UIKitBridge
(M2 UI slice) behind the same `UpdateSource` protocol.

## M2 — UIKitBridge (Packages/UIKitBridge, macOS only)
`VisionImageFeatureProvider: ImageFeatureProvider` (Vision feature prints),
`HomebrewUpdateSource: UpdateSource` (runs `brew outdated --cask --json=v2` via Process),
`AppStoreUpdateSource: UpdateSource` (iTunes lookup API by bundle id),
`PowerState.isOnBattery` via IOKit.
