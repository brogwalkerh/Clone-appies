import AppIntents
import Foundation
import CleanerCore
import CleanupModule

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

    private init() {}

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
        "Releases inactive memory. Part of the Performance module.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Memory purging needs the privileged helper and ships with Performance in M3.
        .result(dialog: "Free Up RAM arrives with the Performance module in M3.")
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
                "Free up memory with \(.applicationName)"
            ],
            shortTitle: "Free Up RAM",
            systemImageName: "memorychip"
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
