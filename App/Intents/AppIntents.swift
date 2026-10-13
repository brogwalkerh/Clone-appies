import AppIntents
import Foundation
import CleanerCore
import CleanupModule
import ClutterModule
import ApplicationsModule
import HelperProtocol
import PerformanceModule

// macOS 27 Siri AI acts in third-party apps only through App Intents, and the
// rebuilt Spotlight indexes the same intents as actions (PLAN.md §2). Every
// user-facing action must therefore be reachable from this file. Phrases live
// in `MacCleanerShortcuts`; `MacCleanerApp.init` calls
// `updateAppShortcutParameters()` so the system discovers them at launch.

// MARK: - Shared services

/// Bridge between intents and the running app. Intents may run with no window
/// open, so everything here works with `appState == nil` and only mirrors
/// results into the UI when it exists.
@MainActor
final class AppServices {
    static let shared = AppServices()

    weak var appState: AppState?

    /// Inventory used when an intent runs with no window (and therefore no `AppState`).
    private var standaloneInventory: AppInventoryStore?

    private init() {}

    /// The live `AppInventoryStore` when the app is running, else a private one
    /// so Siri can list and uninstall apps without a window.
    func inventory() -> AppInventoryStore {
        if let appState {
            return appState.appInventory
        }
        if let standaloneInventory {
            return standaloneInventory
        }
        let store = AppInventoryStore()
        standaloneInventory = store
        return store
    }

    /// Discovered apps, refreshing once if nothing has been discovered yet.
    func installedApps() async -> [InstalledApp] {
        let store = inventory()
        await store.refreshIfNeeded()
        return store.apps
    }

    /// Runs the Duplicates scanner with a private coordinator and returns the findings.
    func scanDuplicates() async -> (findings: [Finding], summary: ScanSummary?) {
        let coordinator = ScanCoordinator(scanners: [DuplicatesScanner()])
        var findings: [Finding] = []
        var summary: ScanSummary?
        for await event in await coordinator.run(scanContext()) {
            switch event {
            case .finding(let finding):
                findings.append(finding)
            case .completed(let scanSummary):
                summary = scanSummary
            default:
                break
            }
        }
        return (findings, summary)
    }

    func recordUninstall(_ manifest: RemovalManifest, appName: String) {
        appState?.lastRemovalManifests[.applications] = manifest
        appState?.post(title: "Uninstalled \(appName) via Siri",
                       message: "Reclaimed \(ByteFormatter.string(manifest.bytesReclaimed)).")
    }

    func scanContext() -> ScanContext {
        SettingsStore.scanContext()
    }

    func remover() -> any Remover {
        GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default)
    }

    func removalMode() -> RemovalMode {
        SettingsStore.removalMode()
    }

    /// Runs a complete Cleanup scan with a private coordinator and returns the results.
    func scanCleanup() async -> (findings: [Finding], summary: ScanSummary?) {
        let coordinator = ScanCoordinator(scanners: CleanupScanners.all())
        var findings: [Finding] = []
        var summary: ScanSummary?
        for await event in await coordinator.run(scanContext()) {
            switch event {
            case .finding(let finding):
                findings.append(finding)
            case .completed(let scanSummary):
                summary = scanSummary
            default:
                break
            }
        }
        if let summary {
            appState?.record(summary: summary, for: .cleanup)
        }
        return (findings, summary)
    }

    func recordCleanup(_ manifest: RemovalManifest) {
        appState?.lastCleanupManifest = manifest
        appState?.post(title: "Cleanup finished via Siri",
                       message: "Reclaimed \(ByteFormatter.string(manifest.bytesReclaimed)).")
    }

    func show(_ item: SidebarItem) {
        appState?.select(item)
    }

    // MARK: Maintenance

    /// Re-checks the helper so an intent that runs with no window sees the truth.
    func helperIsAvailable() async -> Bool {
        await HelperClient.shared.checkAvailability()
        return HelperClient.shared.isAvailable
    }

    enum MaintenanceOutcome: Sendable {
        case needsHelper
        case finished(MaintenanceResult)
    }

    /// Runs one catalog task through the same `MaintenanceRunner` the Performance
    /// screen uses, mirroring the result into `AppState` when a window exists.
    func runMaintenance(_ task: MaintenanceTask) async -> MaintenanceOutcome {
        let helperAvailable = await helperIsAvailable()
        if task.requiresHelper, !helperAvailable {
            return .needsHelper
        }
        if let appState, !appState.maintenance.isRunning {
            // Drive the shared state so the Performance screen shows this run too.
            appState.maintenance.selectedTaskIDs = [task.id]
            appState.maintenance.run([task], helperAvailable: helperAvailable)
            while appState.maintenance.isRunning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if let result = appState.maintenance.results[task.id] {
                postMaintenance(result, task: task)
                return .finished(result)
            }
        }
        let result = await MaintenanceState.makeRunner().run(task)
        postMaintenance(result, task: task)
        return .finished(result)
    }

    private func postMaintenance(_ result: MaintenanceResult, task: MaintenanceTask) {
        let reclaimed = result.bytesReclaimed.map { " Reclaimed \(ByteFormatter.string($0))." } ?? ""
        appState?.post(title: result.succeeded ? "\(task.name) finished via Siri" : "\(task.name) failed",
                       message: result.message + reclaimed)
    }
}

// MARK: - Intents

struct RunSmartCareIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Smart Care"
    static let description: IntentDescription? = IntentDescription(
        "Checks your Mac for junk, threats, slowdowns, outdated apps and clutter in one run.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppServices.shared.show(.smartCare)
        return .result(dialog: "Smart Care's combined scan arrives in M5. I opened Smart Care; you can run Cleanup from there now.")
    }
}

struct CleanJunkIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean System Junk"
    static let description: IntentDescription? = IntentDescription(
        "Scans for caches, logs and other junk, then moves the safe items to the Trash after you confirm.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let scan = await AppServices.shared.scanCleanup()
        let safe = scan.findings.filter { $0.risk != .risky }
        let bytes = safe.reduce(Int64(0)) { $0 + $1.sizeBytes }

        guard !safe.isEmpty else {
            return .result(dialog: "No junk found. Your Mac is already tidy.")
        }

        // TODO(macOS27): verify `requestConfirmation(result:confirmationActionName:)`
        // is still the preferred confirmation API in the 27 SDK.
        try await requestConfirmation(
            result: .result(dialog: "Found \(ByteFormatter.string(bytes)) of junk in \(safe.count) items. Move it to the Trash?"),
            confirmationActionName: .continue)

        let remover = await AppServices.shared.remover()
        let manifest = try await remover.remove(safe, mode: .trash, progress: nil)
        await AppServices.shared.recordCleanup(manifest)

        let failed = manifest.records.filter { !$0.succeeded }.count
        let tail = failed > 0 ? " \(failed) items could not be moved." : " You can undo this from the Cleanup module."
        return .result(dialog: "Reclaimed \(ByteFormatter.string(manifest.bytesReclaimed)).\(tail)")
    }
}

struct FindLargeFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Large Files"
    static let description: IntentDescription? = IntentDescription(
        "Lists the largest files in your home folder above a size threshold.")
    static let openAppWhenRun = false

    @Parameter(title: "Minimum size (MB)", default: 500)
    var minimumSizeMB: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find files larger than \(\.$minimumSizeMB) MB")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let threshold = Int64(max(minimumSizeMB, 1)) * 1_000_000
        let entries = try await LargeFileFinder.find(minimumBytes: threshold, limit: 20)
        let paths = entries.map { $0.url.path(percentEncoded: false) }

        guard let largest = entries.first else {
            return .result(value: paths,
                           dialog: "No files larger than \(minimumSizeMB) MB in your home folder.")
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let dialog: IntentDialog = "Found \(entries.count) files over \(minimumSizeMB) MB, \(ByteFormatter.string(total)) in total. The largest is \(largest.url.lastPathComponent) at \(ByteFormatter.string(largest.sizeBytes))."
        return .result(value: paths, dialog: dialog)
    }
}

struct FreeUpRAMIntent: AppIntent {
    static let title: LocalizedStringResource = "Free Up RAM"
    static let description: IntentDescription? = IntentDescription(
        "Releases inactive memory by running the Free Up RAM maintenance task.")
    static let openAppWhenRun = false

    static let taskID = "maintenance.freeRAM"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let task = MaintenanceState.task(withID: FreeUpRAMIntent.taskID) else {
            return .result(dialog: "Free Up RAM is not available in this build.")
        }
        return .result(dialog: await MaintenanceDialogs.dialog(for: AppServices.shared.runMaintenance(task), task: task))
    }
}

// MARK: - Maintenance entity

/// A `MaintenanceCatalog` task as Siri / Shortcuts sees it.
struct MaintenanceTaskEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Maintenance Task")
    static let defaultQuery = MaintenanceTaskQuery()

    let id: String
    let name: String
    let summary: String
    let requiresHelper: Bool

    init(_ task: MaintenanceTask) {
        id = task.id
        name = task.name
        summary = task.summary
        requiresHelper = task.requiresHelper
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }

    var task: MaintenanceTask? { MaintenanceState.task(withID: id) }
}

struct MaintenanceTaskQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MaintenanceTaskEntity] {
        let wanted = Set(identifiers)
        return MaintenanceCatalog.all.filter { wanted.contains($0.id) }.map(MaintenanceTaskEntity.init)
    }

    func entities(matching string: String) async throws -> [MaintenanceTaskEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return MaintenanceCatalog.all
            .filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.summary.localizedCaseInsensitiveContains(needle) }
            .map(MaintenanceTaskEntity.init)
    }

    /// Catalog order; safe tasks first so the picker starts with the harmless ones.
    func suggestedEntities() async throws -> [MaintenanceTaskEntity] {
        MaintenanceCatalog.all
            .sorted { lhs, rhs in
                if lhs.risk != rhs.risk { return lhs.risk < rhs.risk }
                return false
            }
            .map(MaintenanceTaskEntity.init)
    }
}

struct RunMaintenanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Maintenance Task"
    static let description: IntentDescription? = IntentDescription(
        "Runs one Performance maintenance task such as Flush DNS Cache or Reindex Spotlight. Tasks that need administrator rights go through the privileged helper.")
    static let openAppWhenRun = false

    @Parameter(title: "Task")
    var task: MaintenanceTaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$task)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let catalogTask = task.task else {
            return .result(dialog: "\(task.name) is not available in this build.")
        }
        if catalogTask.risk == .risky {
            // TODO(macOS27): verify `requestConfirmation(result:confirmationActionName:)`
            // is still the preferred confirmation API in the 27 SDK.
            try await requestConfirmation(
                result: .result(dialog: "\(catalogTask.name): \(catalogTask.summary) Run it now?"),
                confirmationActionName: .continue)
        }
        return .result(dialog: await MaintenanceDialogs.dialog(for: AppServices.shared.runMaintenance(catalogTask), task: catalogTask))
    }
}

enum MaintenanceDialogs {
    static func dialog(for outcome: AppServices.MaintenanceOutcome, task: MaintenanceTask) -> IntentDialog {
        switch outcome {
        case .needsHelper:
            return "\(task.name) needs the privileged helper, which is not installed. Open Mac Cleaner › Settings › Advanced and choose Install, then try again."
        case .finished(let result):
            if result.succeeded {
                if let bytes = result.bytesReclaimed, bytes > 0 {
                    return "\(task.name) finished and reclaimed \(ByteFormatter.string(bytes))."
                }
                return "\(task.name) finished. \(result.message)"
            }
            return "\(task.name) failed: \(result.message)"
        }
    }
}

// MARK: - Applications entity

/// An installed app as Siri / Shortcuts sees it. Identified by bundle path so
/// two copies of the same app (e.g. /Applications and ~/Applications) stay distinct.
struct InstalledAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Application")
    static let defaultQuery = InstalledAppQuery()

    /// Standardized bundle path.
    let id: String
    let name: String
    let version: String?
    let isSystem: Bool

    init(_ app: InstalledApp) {
        id = AppInventoryStore.normalizedPath(app.bundleURL)
        name = app.name
        version = app.version
        isSystem = app.isSystem
    }

    var displayRepresentation: DisplayRepresentation {
        let subtitle: LocalizedStringResource? = version.map { "Version \($0)" }
        return DisplayRepresentation(title: "\(name)", subtitle: subtitle)
    }
}

struct InstalledAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [InstalledAppEntity] {
        let wanted = Set(identifiers)
        return await AppServices.shared.installedApps()
            .map(InstalledAppEntity.init)
            .filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [InstalledAppEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return await AppServices.shared.installedApps()
            .filter { $0.name.localizedCaseInsensitiveContains(needle) }
            .map(InstalledAppEntity.init)
    }

    /// Removable apps, most recently opened first, so the picker starts useful.
    func suggestedEntities() async throws -> [InstalledAppEntity] {
        let apps = await AppServices.shared.installedApps()
        return apps
            .filter { !$0.isSystem }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            .prefix(30)
            .map(InstalledAppEntity.init)
    }
}

struct UninstallAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Uninstall App"
    static let description: IntentDescription? = IntentDescription(
        "Moves an app and the support files it left behind to the Trash after you confirm. System apps are never touched.")
    static let openAppWhenRun = false

    @Parameter(title: "App")
    var app: InstalledAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Uninstall \(\.$app)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = await AppServices.shared.inventory()
        _ = await AppServices.shared.installedApps()
        guard let installed = await store.app(withPath: app.id) else {
            return .result(dialog: "\(app.name) is no longer installed.")
        }
        guard !installed.isSystem else {
            return .result(dialog: "\(installed.name) is part of macOS and cannot be uninstalled.")
        }

        let leftovers = await store.leftovers(for: installed)
        let bytes = installed.sizeBytes + leftovers.reduce(Int64(0)) { $0 + $1.sizeBytes }

        // TODO(macOS27): verify `requestConfirmation(result:confirmationActionName:)`
        // is still the preferred confirmation API in the 27 SDK.
        try await requestConfirmation(
            result: .result(dialog: "Move \(installed.name) and \(leftovers.count) support files (\(ByteFormatter.string(bytes))) to the Trash?"),
            confirmationActionName: .continue)

        let remover = await AppServices.shared.remover()
        let manifest = try await store.uninstall(installed, leftovers: leftovers, using: remover, mode: .trash)
        await AppServices.shared.recordUninstall(manifest, appName: installed.name)

        let failed = manifest.records.filter { !$0.succeeded }.count
        let tail = failed > 0 ? " \(failed) items could not be moved." : " You can undo this from the Applications module."
        return .result(dialog: "Uninstalled \(installed.name) and reclaimed \(ByteFormatter.string(manifest.bytesReclaimed)).\(tail)")
    }
}

struct FindDuplicatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Duplicate Files"
    static let description: IntentDescription? = IntentDescription(
        "Looks for byte-identical files in Documents, Desktop, Downloads, Movies, Music and Pictures. Nothing is removed.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let scan = await AppServices.shared.scanDuplicates()
        let paths = scan.findings
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .map { $0.path.path(percentEncoded: false) }
        await AppServices.shared.show(.myClutter)

        guard !scan.findings.isEmpty else {
            return .result(value: paths, dialog: "No duplicate files found.")
        }
        let bytes = scan.findings.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let dialog: IntentDialog = "Found \(scan.findings.count) duplicate files taking \(ByteFormatter.string(bytes)). Review them in My Clutter › Duplicates."
        return .result(value: paths, dialog: dialog)
    }
}

// MARK: - Shortcuts

struct MacCleanerShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunSmartCareIntent(),
            phrases: [
                "Run Smart Care in \(.applicationName)",
                "Free up space on my Mac with \(.applicationName)",
                "Tune up my Mac with \(.applicationName)"
            ],
            shortTitle: "Run Smart Care",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: CleanJunkIntent(),
            phrases: [
                "Clean junk with \(.applicationName)",
                "Clean system junk in \(.applicationName)",
                "Clear caches with \(.applicationName)"
            ],
            shortTitle: "Clean Junk",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: FindLargeFilesIntent(),
            phrases: [
                "Find large files with \(.applicationName)",
                "Show my biggest files in \(.applicationName)"
            ],
            shortTitle: "Find Large Files",
            systemImageName: "doc.badge.ellipsis"
        )
        AppShortcut(
            intent: FreeUpRAMIntent(),
            phrases: [
                "Free up RAM with \(.applicationName)",
                "Free up memory with \(.applicationName)",
                "Purge inactive memory using \(.applicationName)"
            ],
            shortTitle: "Free Up RAM",
            systemImageName: "memorychip"
        )
        AppShortcut(
            intent: RunMaintenanceIntent(),
            phrases: [
                "Run maintenance with \(.applicationName)",
                "Run \(\.$task) with \(.applicationName)",
                "Run the \(\.$task) task in \(.applicationName)"
            ],
            shortTitle: "Run Maintenance",
            systemImageName: "gauge.with.dots.needle.67percent"
        )
        AppShortcut(
            intent: UninstallAppIntent(),
            phrases: [
                "Uninstall an app with \(.applicationName)",
                "Uninstall \(\.$app) with \(.applicationName)",
                "Remove \(\.$app) completely using \(.applicationName)"
            ],
            shortTitle: "Uninstall App",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: FindDuplicatesIntent(),
            phrases: [
                "Find duplicates with \(.applicationName)",
                "Find duplicate files in \(.applicationName)"
            ],
            shortTitle: "Find Duplicates",
            systemImageName: "doc.on.doc"
        )
    }
}

// MARK: - Large file search

/// Walks the home folder with `FileWalker` and keeps the largest files.
/// Lives here until My Clutter (M2) ships its Large & Old scanner.
enum LargeFileFinder {
    struct Entry: Sendable, Hashable {
        let url: URL
        let sizeBytes: Int64
    }

    static func find(in root: URL? = nil,
                     minimumBytes: Int64,
                     limit: Int,
                     maxDepth: Int = 8) async throws -> [Entry] {
        let fileSystem = LocalFileSystem()
        let start = root ?? fileSystem.homeDirectory()
        let walker = FileWalker(fileSystem: fileSystem, followsSymlinks: false, skipsPackageContents: true)
        let protected = ProtectedPaths.default
        var results: [Entry] = []

        for try await (url, attributes) in walker.walk(start, maxDepth: maxDepth) {
            try Task.checkCancellation()
            guard !attributes.isDirectory,
                  attributes.sizeBytes >= minimumBytes,
                  !protected.isProtected(url) else { continue }
            results.append(Entry(url: url, sizeBytes: attributes.sizeBytes))
        }
        return Array(results.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit))
    }
}
