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
M5 adds `smart-care [--home] [--json] [--run --yes] [--no-malware]`, `actions list|run <name|id>
[--dry-run]` and `activity [--weeks N] [--json]`; all three take `--data-dir PATH` and
`--no-history` and share the app's SmartCareStorage files.

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
  trash on every platform (for tests). In `.trash` mode `TrashRemover` deletes a
  finding that is already inside a Trash (`~/.Trash`, `/Volumes/*/.Trashes/<uid>`,
  the configured trash directory) instead of re-trashing it; its record has
  `trashedTo == nil` (CLAUDE.md rule 3: emptying the Trash). `CleanerCoreTesting` ships `MockFileSystem`
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

## M3 — HelperProtocol (Packages/HelperProtocol, Foundation-only)

The privileged helper exposes a **closed** set of operations (CLAUDE.md rule 5).
Every request is a `Codable` enum case with typed, validated arguments. The
package is Foundation-only so validation is unit-tested on Linux; the XPC
transport lives in `PrivilegedHelper/` and `App/Services/HelperClient.swift`.

```swift
public enum HelperOperation: Codable, Sendable, Hashable {
    case ping
    case freePurgeableSpace                       // runs /usr/sbin/purge-equivalent: `tmutil thinlocalsnapshots / 9999999999 4` + `purge`
    case flushDNSCache                            // dscacheutil -flushcache; killall -HUP mDNSResponder
    case runPeriodicScripts(PeriodicInterval)     // periodic daily|weekly|monthly
    case reindexSpotlight(volume: String)         // mdutil -E <volume>; volume must be "/" or under /Volumes/
    case rebuildLaunchServices                    // lsregister -kill -r -domain local -domain system -domain user
    case thinLocalSnapshots(bytesToFree: Int64)   // tmutil thinlocalsnapshots / <bytes> 4
    case removeSystemCache(path: String)          // path must be under /Library/Caches or /private/var/folders, no "..", not a symlink
    case setLaunchDaemonEnabled(label: String, enabled: Bool)   // label must match ^[A-Za-z0-9_.-]+$ and not start with com.apple.
    case resetBluetoothModule                     // kills bluetoothd (launchd restarts it)
    case speedUpMail                              // sqlite3 VACUUM on ~/Library/Mail/V*/MailData/Envelope\ Index for the calling user's home (path passed, validated)
}
public enum PeriodicInterval: String, Codable, Sendable { case daily, weekly, monthly }

public struct HelperRequest: Codable, Sendable, Hashable {
    public let id: UUID
    public let operation: HelperOperation
    public let callerHome: String        // validated: absolute, under /Users/ or /var/root
    public init(operation: HelperOperation, callerHome: String)
}
public struct HelperResponse: Codable, Sendable, Hashable {
    public let requestID: UUID
    public let succeeded: Bool
    public let message: String
    public let bytesReclaimed: Int64?
    public let durationSeconds: Double
}
public enum HelperValidationError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidPath(String), outsideAllowedRoot(String), invalidLabel(String), invalidVolume(String), invalidHome(String)
}
/// Pure validation, no I/O except an injected symlink check. Used by BOTH sides.
public struct HelperRequestValidator: Sendable {
    public init(isSymlink: @Sendable (String) -> Bool = { _ in false })
    public func validate(_ request: HelperRequest) throws   // throws HelperValidationError
}
/// The fixed argv for each operation, so the helper never builds command lines from strings it did not author.
public struct HelperCommandPlan: Sendable, Hashable {
    public let steps: [(executable: String, arguments: [String])]   // represent as [CommandStep]
    public static func plan(for operation: HelperOperation, callerHome: String) -> HelperCommandPlan
}
public struct CommandStep: Sendable, Hashable, Codable { public let executable: String; public let arguments: [String] }

/// XPC wire protocol (ObjC-visible). Lives in the same package behind #if canImport(ObjectiveC).
@objc public protocol HelperXPCProtocol {
    func perform(_ requestData: Data, reply: @escaping (Data) -> Void)   // JSON HelperRequest -> JSON HelperResponse
    func version(reply: @escaping (String) -> Void)
}
public enum HelperConstants { public static let machServiceName = "com.example.maccleaner.helper"; public static let version = "1" }
```

## M3 — App side of the helper (App/Services/HelperClient.swift, macOS only)
```swift
@MainActor @Observable public final class HelperClient {
    public static let shared: HelperClient
    public private(set) var isAvailable: Bool
    public func perform(_ operation: HelperOperation) async throws -> HelperResponse   // validates locally first, then XPC
    public func checkAvailability() async
}
```
Code-signing: the helper verifies the connecting process with
`SecCodeCheckValidity` against a requirement string naming our Team ID and
bundle id (`HelperConstants.clientRequirement`), and the client sets the same
on the `NSXPCConnection` via `setCodeSigningRequirement(_:)` (macOS 13+).

## M3 — PerformanceModule (Packages/Modules/Performance, Foundation-only)

```swift
public struct MaintenanceTask: Sendable, Hashable, Codable, Identifiable {
    public let id: String                 // "maintenance.freeRAM"
    public let name: String
    public let summary: String            // one line
    public let detail: String             // Smart Insights style explanation
    public let requiresHelper: Bool
    public let helperOperation: HelperOperation?
    public let risk: RiskLevel
    public let estimatedSeconds: Int
}
public enum MaintenanceCatalog {
    public static let all: [MaintenanceTask]   // freeRAM, freePurgeable, runPeriodic (daily+weekly+monthly), flushDNS, reindexSpotlight,
                                               // rebuildLaunchServices, thinSnapshots, speedUpMail, resetBluetooth, clearFontCaches (user-level), 
                                               // repairUserPermissions (user-level: `diskutil resetUserPermissions / $(id -u)`)
}
public struct MaintenanceResult: Sendable, Hashable, Codable { public let taskID: String; public let succeeded: Bool; public let message: String; public let bytesReclaimed: Int64?; public let duration: TimeInterval }

/// Executes tasks. User-level tasks run via the injected `CommandRunner`; helper tasks via the injected `HelperPerformer`.
public protocol CommandRunner: Sendable { func run(_ step: CommandStep) async throws -> (exitCode: Int32, stdout: String, stderr: String) }
public protocol HelperPerformer: Sendable { func perform(_ operation: HelperOperation) async throws -> HelperResponse }
public actor MaintenanceRunner {
    public init(commands: any CommandRunner, helper: (any HelperPerformer)?, home: URL)
    public func run(_ task: MaintenanceTask) async -> MaintenanceResult
    public func run(_ tasks: [MaintenanceTask]) -> AsyncStream<MaintenanceResult>
}
public struct ProcessCommandRunner: CommandRunner { public init() }   // Foundation.Process; on Linux fine for tests with /bin/echo

/// Login & background items from launchd plists. Pure parsing; `enabledState` is nil when unknown (Linux).
public struct BackgroundItem: Sendable, Hashable, Codable, Identifiable {
    public var id: URL { plistURL }
    public let plistURL: URL
    public let label: String
    public let domain: BackgroundItemDomain       // userAgent, systemAgent, systemDaemon, loginItemApp
    public let program: String?                   // Program or ProgramArguments[0]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let isBroken: Bool                     // program path does not exist
    public let isApple: Bool                      // label starts with com.apple.
    public let ownerAppName: String?              // best-effort from path / label
    public let enabledState: Bool?
}
public enum BackgroundItemDomain: String, Codable, Sendable { case userAgent, systemAgent, systemDaemon, loginItemApp }
public struct BackgroundItemsInventory: Sendable {
    public init(fileSystem: any FileSystem, enabledStateProvider: (any LaunchdStateProvider)? = nil)
    public func discover(home: URL) async throws -> [BackgroundItem]
}
public protocol LaunchdStateProvider: Sendable { func isEnabled(label: String, domain: BackgroundItemDomain) async -> Bool? }
/// id "performance.brokenLoginItems": emits each broken BackgroundItem's plist as a Finding, category "performance.brokenLoginItems", risk .safe.
public struct BrokenLoginItemsScanner: CleanerScanner { public init() }
public enum PerformanceScanners { public static func all() -> [any CleanerScanner] }

/// Heavy consumers: sampling is platform-specific (UIKitBridge); ranking is here.
public struct ProcessSample: Sendable, Hashable, Codable, Identifiable {
    public let id: Int32            // pid
    public let name: String
    public let bundleIdentifier: String?
    public let cpuPercent: Double   // 0...100*cores
    public let residentBytes: Int64
    public let energyImpact: Double?   // nil when unavailable
    public let isResponsive: Bool?     // nil when unknown
    public let isSystem: Bool
}
public protocol ProcessSampler: Sendable { func sample() async throws -> [ProcessSample] }
public struct HeavyConsumersRanker: Sendable {
    public init(cpuThreshold: Double = 20, memoryThreshold: Int64 = 1_000_000_000)
    public func rank(_ samples: [ProcessSample]) -> [ProcessSample]   // heavy first; excludes system procs below thresholds; stable
    public func hung(_ samples: [ProcessSample]) -> [ProcessSample]
}
```

## M3 — UIKitBridge additions (macOS only)
```swift
public struct DarwinProcessSampler: ProcessSampler { public init() }           // proc_listallpids + proc_pid_rusage + NSRunningApplication; isResponsive via AXUIElement with 1s messaging timeout
public struct LaunchctlStateProvider: LaunchdStateProvider { public init() }   // `launchctl print gui/<uid>/<label>` / system/<label>
public struct SystemStats: Sendable, Hashable { cpuPercent, memoryUsedBytes, memoryTotalBytes, memoryPressure (normal|warn|critical), diskUsedBytes, diskTotalBytes, purgeableBytes, batteryPercent?, batteryCycleCount?, batteryHealth?, isCharging?, networkInBytesPerSec, networkOutBytesPerSec }
public actor SystemStatsSampler { public init(interval: Duration = .seconds(2)); public func stream() -> AsyncStream<SystemStats> }   // host_statistics64, host_processor_info deltas, getifaddrs deltas, IOKit power sources
@MainActor public final class ScreenCleaningController { public static let shared; public func begin(duration: Duration = .seconds(120)); public func end(); public var isActive: Bool }
    // Black borderless windows at .screenSaver level on every NSScreen, CGEventTap (needs Accessibility) swallowing keyboard/mouse,
    // countdown label, "hold ⌘ for 2 s to exit", auto-ends; ends cleanly if Accessibility is missing (shows an explanation instead).
```

## M3 — MenuAgent (MenuAgent/, macOS only, LSUIElement)
`MenuBarExtra` with `.window` style; popover shows SystemStats pills (CPU, RAM
with "Free Up", disk with purgeable, battery, network), Trash size, "Run Smart
Care" (opens the main app via `maccleaner://smart-care`), Protection Monitor
row (placeholder until M4), "Screen Cleaning Mode", "Open Mac Cleaner", Quit.
Registered as `SMAppService.loginItem(identifier: "com.example.maccleaner.MenuAgent")`.
Main app declares the `maccleaner` URL scheme (CFBundleURLTypes) and handles
`smart-care`, `cleanup`, `performance` routes.

## M4 — CleanerHashing (new target in Packages/Core, product `CleanerHashing`)
Pure-Swift digests shared by Clutter and Protection. `SHA256`/`StreamingSHA256`
move here from ClutterModule unchanged (Clutter depends on this product and
re-exports via `@_exported import CleanerHashing` so its public API stays).
Adds `MD5` / `StreamingMD5` with the same shape, tested against RFC 1321 vectors.

## M4 — ProtectionModule (Packages/Modules/Protection, Foundation-only)

```swift
public enum ScanScope: String, Codable, Sendable, CaseIterable { case quick, normal, deep }

public enum ThreatSeverity: String, Codable, Sendable, Comparable { case low, medium, high, critical }
public enum ThreatKind: String, Codable, Sendable { case signature, heuristic }
public struct Threat: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID; public let path: URL; public let name: String      // "Eicar-Test-Signature", "Heuristic.UnsignedLaunchAgent"
    public let kind: ThreatKind; public let severity: ThreatSeverity; public let detail: String
    public let sizeBytes: Int64; public let isDirectory: Bool
    public var finding: Finding { get }   // category "protection.malware", risk .safe, detail "<name>: <detail>"
}

/// ClamAV text formats. Parsing is tolerant: malformed lines are skipped and counted.
public struct SignatureDatabase: Sendable {
    public struct Stats: Sendable, Hashable { public let hashSignatures: Int; public let patternSignatures: Int; public let allowlisted: Int; public let skippedLines: Int }
    public init()
    public mutating func load(hdb text: String)        // md5:size:name   (size may be "*")
    public mutating func load(hsb text: String)        // sha256:size:name
    public mutating func load(ndb text: String)        // name:target:offset:hexpattern  (target 0 any, 1 PE, 6 ELF, 9 Mach-O; offset "*" or int or "EOF-n")
    public mutating func load(ign2 text: String)       // signature names to ignore
    public mutating func load(contentsOf directory: URL, fileSystem: any FileSystem) throws   // by extension
    public static func bundledStarter() -> SignatureDatabase   // Resources/signatures/*.hdb,*.ndb incl. EICAR
    public var stats: Stats { get }
    public func match(md5: String, sha256: String, size: Int64) -> String?
    public var patterns: [HexPattern] { get }
}
public struct HexPattern: Sendable, Hashable { public let name: String; public let target: Int; public let offset: PatternOffset; public let tokens: [PatternToken] }
public enum PatternOffset: Sendable, Hashable { case any, absolute(Int), fromEnd(Int) }
public enum PatternToken: Sendable, Hashable { case byte(UInt8), wildcardByte, nibbleHigh(UInt8), nibbleLow(UInt8), skipAny, skipRange(min: Int, max: Int) }
public struct PatternMatcher: Sendable {
    public init(patterns: [HexPattern])
    public func matches(in data: Data, fileSize: Int64, chunkOffset: Int64) -> [String]   // names; caller streams chunks with overlap >= maxPatternLength
    public var maxPatternLength: Int { get }
}

/// Heuristics are pure functions over file metadata + small reads; platform facts injected.
public protocol CodeSignatureVerifier: Sendable { func isValidlySigned(_ executable: URL) async -> Bool? }   // nil = unknown (Linux)
public protocol RunningProcessPathsProvider: Sendable { func executablePaths() async -> [URL] }
public struct HeuristicContext: Sendable {
    public let fileSystem: any FileSystem; public let home: URL
    public let signatureVerifier: (any CodeSignatureVerifier)?; public let now: Date
}
public struct Heuristics: Sendable {
    public init()
    public func evaluate(launchAgentPlist url: URL, context: HeuristicContext) async -> [Threat]   // curl|bash, osascript -e, base64 -d, /tmp or hidden paths, unsigned program, program missing from bundle
    public func evaluate(executable url: URL, attributes: FileAttributes, context: HeuristicContext) async -> [Threat]   // executable in hidden dir under ~/Library, masquerading extension (magic bytes vs .jpg/.pdf/.txt), script with #! in LaunchAgents
}

public struct ScanScopeResolver: Sendable {
    public init(fileSystem: any FileSystem, runningProcesses: (any RunningProcessPathsProvider)? = nil)
    /// quick: running executables, ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons programs, ~/Downloads, ~/Desktop, apps modified < 7 days
    /// normal: quick + home + /Applications + /Library/LaunchAgents + /Library/LaunchDaemons + /usr/local
    /// deep: normal + every mounted volume under /Volumes except protected/Time Machine
    public func roots(for scope: ScanScope, home: URL, now: Date) async -> [URL]
}

/// The scanner. id "protection.malware". Streams Threat-derived Findings. Hashes every regular file
/// (MD5+SHA-256 in one streaming pass), applies patterns to files whose target type matches (by magic
/// bytes: Mach-O 0xFEEDFACE/0xFEEDFACF/0xCAFEBABE, PE "MZ", ELF 0x7F"ELF", scripts "#!") up to maxFileSize,
/// skips allowlisted names, runs heuristics on launch agents and executables. Respects ignore list and
/// protected paths. Emits progress by root.
public struct MalwareScanner: CleanerScanner {
    public init(scope: ScanScope, database: SignatureDatabase, verifier: (any CodeSignatureVerifier)? = nil,
                runningProcesses: (any RunningProcessPathsProvider)? = nil, maxFileSize: Int64 = 200_000_000)
}
public enum ProtectionScanners { public static func make(scope: ScanScope, database: SignatureDatabase, verifier: (any CodeSignatureVerifier)?, runningProcesses: (any RunningProcessPathsProvider)?) -> [any CleanerScanner] }  // malware + privacy scanners

/// Quarantine instead of Trash: moves into <quarantineDirectory>/<uuid>/, chmod 000, writes manifest.json.
public actor ThreatQuarantine {
    public init(directory: URL, fileSystem: any FileSystem = LocalFileSystem())
    public func quarantine(_ threats: [Threat]) async -> QuarantineManifest
    public func restore(_ manifest: QuarantineManifest) async -> [QuarantineRecord]
    public func list() async throws -> [QuarantineManifest]
    public func purge(olderThan: TimeInterval) async throws -> Int
}
public struct QuarantineRecord: Codable, Sendable, Hashable { public let threat: Threat; public let storedAt: URL?; public let succeeded: Bool; public let error: String? }
public struct QuarantineManifest: Codable, Sendable, Hashable, Identifiable { public let id: UUID; public let date: Date; public let records: [QuarantineRecord] }

/// Feed: <baseURL>/manifest.json => { "version": "2026-10-13", "files": [ { "name": "mac.hdb", "sha256": "...", "bytes": 1234 } ] }
public struct SignatureUpdater: Sendable {
    public init(baseURL: URL, session: URLSession = .shared, destination: URL)
    public func currentVersion() -> String?
    public func update() async throws -> SignatureUpdateResult   // downloads manifest, fetches changed files, verifies sha256, atomically swaps, writes version
}
public struct SignatureUpdateResult: Sendable, Hashable { public let version: String; public let filesUpdated: Int; public let bytes: Int64 }

/// Privacy: path-based scanners, one per data kind, all risk .caution, categories "privacy.<kind>".
/// Browsers: Safari (History.db, Downloads.plist, LocalStorage, Cookies), Chrome/Chromium/Brave/Edge/Arc/Vivaldi
/// (History, Cookies, Cache, Login Data NOT touched, Top Sites, Visited Links), Firefox (places.sqlite history only
/// via a copy? no — report the profile's cache2 and cookies.sqlite; places is .risky with detail "Removes bookmarks too").
/// System: recent items (com.apple.sharedfilelist/*.sfl3), QuickLook thumbnail cache, Wi-Fi known networks (report-only on
/// Linux; macOS removal needs the helper — mark .risky and requiresHelper detail), chat caches (Slack, Discord, Teams, Telegram, WhatsApp).
public enum PrivacyScanners { public static func all() -> [any CleanerScanner] }

/// Permissions review model. The reader is platform-specific (UIKitBridge reads TCC.db with SQLite3).
public enum PrivacyService: String, Codable, Sendable, CaseIterable { case camera, microphone, fullDiskAccess, accessibility, screenRecording, location, contacts, calendars, photos, inputMonitoring, automation }
public struct PermissionGrant: Sendable, Hashable, Codable, Identifiable { public var id: String { "\(service.rawValue):\(clientID)" }; public let service: PrivacyService; public let clientID: String; public let clientName: String?; public let granted: Bool; public let lastModified: Date? }
public protocol PermissionsReader: Sendable { func grants() async throws -> [PermissionGrant] }
```

## M4 — UIKitBridge additions (macOS only)
```swift
public struct SecCodeSignatureVerifier: CodeSignatureVerifier { public init() }   // SecStaticCodeCreateWithPath + SecStaticCodeCheckValidity(kSecCSDefaultFlags)
public struct RunningProcessPaths: RunningProcessPathsProvider { public init() }   // proc_listallpids + proc_pidpath, deduped
public struct TCCPermissionsReader: PermissionsReader { public init() }           // reads user + system TCC.db via SQLite3; needs FDA; maps kTCCService* to PrivacyService; app names via NSWorkspace
/// FSEvents-based fallback for the Protection Monitor (Endpoint Security is a later entitlement).
public actor ProtectionMonitor {
    public init(paths: [URL] = [~/Downloads, /Applications, ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons], database: SignatureDatabase, verifier: any CodeSignatureVerifier)
    public func start() -> AsyncStream<ProtectionEvent>     // FSEventStreamCreate on a dedicated thread + runloop; debounced; new/changed files hashed + pattern-checked + heuristics; quarantine xattr noted
    public func stop()
}
public enum ProtectionEvent: Sendable { case started, threat(Threat), scanned(URL), stopped(reason: String) }
```
MenuAgent's Protection Monitor row becomes live (green = running, red = threat
found, with count; click opens `maccleaner://protection`). The monitor runs
inside the MenuAgent process so it survives the main window closing.

## M5 — SmartCareModule (Packages/Modules/SmartCare, Foundation-only)

Depends on CleanerCore, CleanupModule (rule descriptions for insights) and
PerformanceModule (maintenance steps in action sets). Persistence follows ADR 0007.

```swift
// MARK: Smart Care run
public enum SmartCareEvent: Sendable {
    case moduleStarted(ModuleID)
    case moduleProgress(ModuleID, fraction: Double?)
    case finding(ModuleID, Finding)
    case scannerFailed(ModuleID, scannerID: String, message: String)
    case moduleFinished(ModuleID, ScanSummary)
    case completed(SmartCareReport)
}
public struct SmartCareReport: Sendable, Hashable, Codable {
    public let startedAt: Date; public let duration: TimeInterval
    public let summaries: [ModuleID: ScanSummary]; public let findings: [Finding]
    public let failures: [String: String]          // scanner id -> message
    public func findings(in module: ModuleID) -> [Finding]
}
/// Which findings Smart Care's single "Run" acts on. Default: non-risky Cleanup and Performance
/// findings; Applications, My Clutter and Protection are "review" modules (nothing auto-selected;
/// threats go through ThreatQuarantine in the Protection flow, never through a Remover).
public struct SmartCarePolicy: Sendable, Hashable {
    public static let `default`: SmartCarePolicy
    public init(autoSelect: [ModuleID: Set<RiskLevel>])
    public func isSelectedByDefault(_ finding: Finding) -> Bool
    public func defaultSelection(_ report: SmartCareReport) -> [Finding]
    public func reclaimableBytes(_ report: SmartCareReport) -> Int64   // bytes of defaultSelection
}
/// One ScanCoordinator per module, all modules concurrently; events merged into one stream.
/// Module order in `modules` is the order of `.moduleStarted`. Ends with `.completed`, also after cancel.
public actor SmartCareCoordinator {
    public init(modules: [(ModuleID, [any CleanerScanner])], maxConcurrencyPerModule: Int = 2)
    public func run(_ context: ScanContext) -> AsyncStream<SmartCareEvent>
    public func cancel()
}

// MARK: Activity (My Activity, PLAN.md §3.12)
public enum ActivityKind: String, Codable, Sendable { case scan, removal, undo, quarantine, maintenance, actionSet }
public struct ActivityEvent: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID; public let date: Date; public let kind: ActivityKind; public let module: ModuleID?
    public let title: String; public let bytes: Int64; public let items: Int; public let reference: String?
    public init(id: UUID = UUID(), date: Date = .now, kind: ActivityKind, module: ModuleID?, title: String,
                bytes: Int64 = 0, items: Int = 0, reference: String? = nil)
    public static func scan(_ summary: ScanSummary, module: ModuleID, date: Date = .now) -> ActivityEvent
    public static func removal(_ manifest: RemovalManifest, module: ModuleID) -> ActivityEvent      // bytes = bytesReclaimed, items = succeeded count, reference = manifest id
    public static func removals(_ manifest: RemovalManifest) -> [ActivityEvent]                    // one per module, for cross-module runs
    public static func undo(_ restored: [RemovalRecord], module: ModuleID, date: Date = .now) -> ActivityEvent
    public static func quarantine(threats: Int, bytes: Int64, date: Date = .now) -> ActivityEvent
    public static func maintenance(_ result: MaintenanceResult, date: Date = .now) -> ActivityEvent
}
public protocol ActivityStore: Sendable {
    func append(_ events: [ActivityEvent]) async throws
    func events(since: Date?) async throws -> [ActivityEvent]   // oldest first
    func removeAll() async throws
}
public actor JSONLinesActivityStore: ActivityStore { public init(fileURL: URL, maxEvents: Int = 5_000) }
public actor InMemoryActivityStore: ActivityStore { public init(_ events: [ActivityEvent] = []) }
public struct ActivityStats: Sendable, Hashable {
    public struct Week: Sendable, Hashable, Identifiable { public var id: Date { start }; public let start: Date; public let bytesByModule: [ModuleID: Int64] }
    public let bytesReclaimed: Int64            // removals minus undos, all time
    public let bytesReclaimedLast30Days: Int64
    public let itemsRemoved: Int; public let threatsQuarantined: Int; public let maintenanceRuns: Int
    public let estimatedTimeSaved: TimeInterval // TimeSavedModel
    public let weeks: [Week]                     // `weeks` buckets ending with the current week, oldest first
    public let lastScan: [ModuleID: Date]; public let lastRemoval: Date?
    public init(events: [ActivityEvent], now: Date, calendar: Calendar = .current, weeks: Int = 8)
}
public enum TimeSavedModel { public static func estimate(_ event: ActivityEvent) -> TimeInterval }  // documented constants

// MARK: Inbox (Notification Center, PLAN.md §3.12)
public enum InboxKind: String, Codable, Sendable { case info, scanResult, reminder, threat, update }
public struct InboxMessage: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID; public let date: Date; public let kind: InboxKind
    public let title: String; public let body: String; public var isRead: Bool; public let link: String?   // maccleaner:// URL
}
/// Whole-file JSON (ADR 0007): every call re-reads, newest first, capped at `capacity`.
public actor InboxStore {
    public init(fileURL: URL, capacity: Int = 50)
    public func messages() -> [InboxMessage]
    @discardableResult public func post(_ message: InboxMessage) -> [InboxMessage]
    @discardableResult public func markRead(_ id: UUID?) -> [InboxMessage]   // nil = all
    @discardableResult public func removeAll() -> [InboxMessage]
}
/// Generic whole-file JSON record used by InboxStore, schedules and action sets.
public struct JSONFileRecord<Value: Codable & Sendable>: Sendable {
    public init(fileURL: URL)
    public func load() -> Value?            // nil when missing or undecodable
    public func save(_ value: Value) throws // atomic, creates parent directory
}

// MARK: Assistant (rule-based, PLAN.md §3.1)
public struct AssistantSnapshot: Sendable, Hashable {
    public var now: Date
    public var lastScan: [ModuleID: Date]; public var summaries: [ModuleID: ScanSummary]
    public var lastSmartCare: Date?; public var lastRemoval: Date?; public var lastMaintenance: Date?
    public var trashBytes: Int64?; public var diskFreeBytes: Int64?; public var diskCapacityBytes: Int64?
    public var hasFullDiskAccess: Bool?; public var helperInstalled: Bool?
    public var updatesAvailable: Int?; public var openThreats: Int; public var signaturesUpdated: Date?
    public var hasEnabledSchedule: Bool
    public init(now: Date = .now)   // everything else empty / nil / 0 / false
}
public enum AssistantDestination: String, Codable, Sendable { case smartCare, cleanup, protection, performance, applications, clutter, spaceLens, myActivity, scheduler }
public enum AssistantAction: Codable, Sendable, Hashable { case open(AssistantDestination), grantFullDiskAccess, installHelper, runSmartCare, updateSignatures }
public struct AssistantRecommendation: Sendable, Hashable, Identifiable {
    public let id: String          // rule id; stable, used for dismissal
    public let priority: Int       // higher first
    public let symbol: String      // SF Symbol name
    public let title: String; public let detail: String; public let action: AssistantAction
}
public protocol AssistantRule: Sendable { var id: String { get }; func evaluate(_ snapshot: AssistantSnapshot) -> AssistantRecommendation? }
public struct Assistant: Sendable {
    public static let defaultRules: [any AssistantRule]   // fullDiskAccess, threats, lowDisk, junk, trash, firstScan, staleScan,
                                                          // updates, signatures, helper, maintenance, schedule
    public init(rules: [any AssistantRule] = Assistant.defaultRules)
    /// Sorted by priority (ties: rule order); a rule dismissed within `dismissalPeriod` is skipped.
    public func recommendations(for snapshot: AssistantSnapshot, dismissed: [String: Date] = [:],
                                dismissalPeriod: TimeInterval = 7 * 86_400, limit: Int = 5) -> [AssistantRecommendation]
}

// MARK: My Tools action sets (PLAN.md §3.12)
public enum ActionStep: Codable, Sendable, Hashable {
    case clean(scannerIDs: [String], includeCaution: Bool)   // scan, then remove .safe (+ .caution if asked) findings; .risky never
    case maintenance(taskID: String)                          // MaintenanceCatalog id
}
public struct ActionSet: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID; public var name: String; public var steps: [ActionStep]; public let createdAt: Date
    public init(id: UUID = UUID(), name: String, steps: [ActionStep], createdAt: Date = .now)
    /// Human-readable problems (empty name, no steps, unknown scanner or task id).
    public func validate(knownScannerIDs: Set<String>, knownTaskIDs: Set<String>) -> [String]
}
public enum ActionSetPresets { public static let all: [ActionSet] }   // "Friday clean", "Developer cleanup", "Quick tune-up"
public struct ActionStepResult: Sendable, Hashable {
    public let index: Int; public let step: ActionStep; public let succeeded: Bool; public let message: String
    public let bytesReclaimed: Int64; public let manifest: RemovalManifest?; public let maintenance: MaintenanceResult?
}
public struct ActionSetReport: Sendable, Hashable { public let actionSetID: UUID; public let results: [ActionStepResult]; public var bytesReclaimed: Int64 { get } }
public enum ActionSetEvent: Sendable { case stepStarted(index: Int, ActionStep), stepFinished(ActionStepResult), completed(ActionSetReport) }
/// Steps run in order; a failing step is recorded and the next one still runs. Removal goes through
/// `remover` (callers pass a GuardedRemover) with `removalMode`; dry runs scan but never remove.
public struct ActionSetRunner: Sendable {
    public init(scanners: [any CleanerScanner], remover: any Remover, maintenance: MaintenanceRunner?,
                removalMode: RemovalMode = .trash, dryRun: Bool = false)
    public func run(_ set: ActionSet, context: ScanContext) -> AsyncStream<ActionSetEvent>
}

// MARK: Scheduler (PLAN.md §3.12)
public enum ScheduleCadence: Codable, Sendable, Hashable { case daily, weekly(weekday: Int), monthly(day: Int) }   // weekday 1 = Sunday; day 1...28
public enum ScheduleTarget: Codable, Sendable, Hashable { case smartCareScan, moduleScan(ModuleID), actionSet(UUID) }
public struct ScanSchedule: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID; public var isEnabled: Bool; public var cadence: ScheduleCadence
    public var hour: Int; public var minute: Int; public var target: ScheduleTarget; public let createdAt: Date
    public init(id: UUID = UUID(), isEnabled: Bool = true, cadence: ScheduleCadence, hour: Int, minute: Int,
                target: ScheduleTarget, createdAt: Date = .now)
    public func nextFire(after date: Date, calendar: Calendar) -> Date?
}
/// Missed occurrences (Mac asleep) collapse into one run on the next check.
public struct ScheduleEvaluator: Sendable {
    public init(calendar: Calendar = .current)
    public func due(_ schedules: [ScanSchedule], lastRuns: [UUID: Date], now: Date) -> [ScanSchedule]
    public func nextFire(_ schedules: [ScanSchedule], lastRuns: [UUID: Date], now: Date) -> Date?
}

// MARK: Smart Insights fallback (PLAN.md §3.2; the Foundation Models provider lives in App/)
public enum InsightSource: String, Codable, Sendable { case rules, onDeviceModel }
public struct Insight: Sendable, Hashable, Codable { public let title: String; public let explanation: String; public let advice: String; public let source: InsightSource }
public protocol InsightProvider: Sendable { func insight(for finding: Finding, home: URL) async -> Insight? }
/// Cleanup rule descriptions by path, then a built-in category table; advice from the finding's risk.
public struct RuleTableInsightProvider: InsightProvider { public init(rules: CleanupRules = .shared) }
/// Asks `primary` (e.g. the on-device model) and falls back when it returns nil.
public struct FallbackInsightProvider: InsightProvider { public init(primary: any InsightProvider, fallback: any InsightProvider) }
/// Prompt text for the on-device model: facts only (path relative to home, size, age, category, rule text).
public enum InsightPrompt { public static let instructions: String; public static func make(for finding: Finding, home: URL, ruleText: String?) -> String }

// MARK: Storage layout (ADR 0007) shared by App, MenuAgent and CLI
public struct SmartCareStorage: Sendable {
    public init(directory: URL)                       // activity.jsonl, inbox.json, schedules.json, schedule-runs.json,
    public let activity: JSONLinesActivityStore       // action-sets.json, assistant-dismissed.json
    public let inbox: InboxStore
    public let schedules: JSONFileRecord<[ScanSchedule]>; public let scheduleRuns: JSONFileRecord<[UUID: Date]>
    public let actionSets: JSONFileRecord<[ActionSet]>; public let dismissedRecommendations: JSONFileRecord<[String: Date]>
    public static func defaultDirectory(home: URL = …) -> URL   // ~/Library/Application Support/com.example.maccleaner
}
```

Implementation notes (SmartCareModule as built):
- Extra public API: `SmartCarePolicy.isReviewOnly(_:)`, `ClosureRule` (closure-backed
  `AssistantRule`; the default rules are written with it), `ActionSetReport.succeeded`,
  `ActivityStats.Week.totalBytes`, `ActivityStats.lastMaintenance`,
  `RuleTableInsightProvider.ruleText(for:home:)`, `ModuleID.displayName`,
  `FindingSelection.droppingNested(_:)`. `SmartCarePolicy.defaultSelection` and the
  action-set clean step drop findings nested inside another selected folder.
- `SmartCareCoordinator` builds module summaries from the findings it keeps, so a path
  two modules report counts once, under whichever module reported it first.
- `JSONLinesActivityStore.append` starts a new line when the file does not end in one,
  so a torn write loses only the torn event.
- Rules never fire on unknown (`nil`) facts; a fresh install sees only "firstScan".

## M5 — App and MenuAgent side (macOS only)
- `ActivityCenter.shared` (`@MainActor @Observable`, App/State) owns the activity log and
  `ActivityStats`. Models record into it where the disk changes, so every path counts once:
  `ScanViewModel` (finished scan, `remove`, `undoLastRemoval`), `MalwareScanModel` (finished
  scan, quarantine), `MaintenanceState` (each result), `AppInventoryStore.uninstall`,
  `AutomationState.run`.
- `SmartCareModel` runs the module view models concurrently (`ScanViewModel.runToCompletion()`,
  `MalwareScanModel.runToCompletion()` with the quick scope, `AppInventoryStore.checkForUpdates()`),
  so each Smart Care card opens a module that already holds its results. Run removes the current
  selection of the modules `SmartCarePolicy` does not mark review-only, via `FindingsActions.clean`.
- `AutomationState` holds action sets (presets plus `SmartCareStorage.actionSets`) and schedules;
  `AppState.runSchedule(id:)` performs a schedule's target and posts the result to the inbox and as
  a system notification. The Notification Center reads and writes `SmartCareStorage.inbox`.
- New deep links: `maccleaner://schedule?id=<uuid>` (run a due schedule, no navigation) and
  `maccleaner://action-set?id=<uuid>`.
- MenuAgent checks `schedules.json` every 60 s with `ScheduleEvaluator`, writes the run time to
  `schedule-runs.json` first, then opens `maccleaner://schedule?id=` without activating the app.
  The agent still never scans or talks to the helper itself (ADR 0002).
- Smart Insights: `InsightService.provider` is `FallbackInsightProvider(primary:
  OnDeviceInsightProvider (Foundation Models, `#if canImport(FoundationModels)`), fallback:
  RuleTableInsightProvider)`; every findings row has a "What is this?" popover.
