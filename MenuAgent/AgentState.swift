import AppKit
import CleanerCore
import Foundation
import Observation
import UIKitBridge

/// Everything the popover observes. Owns the `SystemStatsSampler` task and the
/// periodic Trash measurement; every action that needs the privileged helper
/// or a scan is delegated to the main app through the `maccleaner://` scheme,
/// because the agent deliberately has no helper access (ADR 0002).
@MainActor
@Observable
final class AgentState {
    enum Route {
        static let root = "maccleaner://"
        static let smartCare = "maccleaner://smart-care"
        static let freeRAM = "maccleaner://performance?task=maintenance.freeRAM"
        static let emptyTrash = "maccleaner://cleanup?scanner=cleanup.trash"
    }

    /// Bundle id of the main app, used to launch it when the URL scheme is not
    /// registered yet (first run before Launch Services has seen the app).
    static let mainAppBundleIdentifier = "com.example.maccleaner"

    /// Latest host snapshot; nil until the first sampling interval elapses.
    private(set) var stats: SystemStats?
    /// Size of `~/.Trash`; nil while the first measurement runs.
    private(set) var trashBytes: Int64?
    private(set) var isMeasuringTrash = false

    var isScreenCleaningActive: Bool { ScreenCleaningController.shared.isActive }

    @ObservationIgnored private let sampler: SystemStatsSampler
    @ObservationIgnored private var samplerTask: Task<Void, Never>?
    @ObservationIgnored private var trashTask: Task<Void, Never>?
    @ObservationIgnored private let trashRefreshInterval: Duration = .seconds(60)

    init(sampler: SystemStatsSampler = SystemStatsSampler(interval: .seconds(2))) {
        self.sampler = sampler
        start()
    }

    // MARK: Lifecycle

    func start() {
        guard samplerTask == nil else { return }
        samplerTask = Task { [weak self, sampler = self.sampler] in
            let stream = await sampler.stream()
            for await snapshot in stream {
                guard let self else { return }
                self.stats = snapshot
            }
        }
        trashTask = Task { [weak self, interval = self.trashRefreshInterval] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshTrash()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        samplerTask?.cancel()
        trashTask?.cancel()
        samplerTask = nil
        trashTask = nil
    }

    // MARK: Trash

    /// Sums the user's Trash with `FileWalker.directorySize`. Per-volume
    /// `.Trashes` folders are not included; the main app's Trash scanner is the
    /// authority for the real number.
    func refreshTrash() async {
        guard !isMeasuringTrash else { return }
        isMeasuringTrash = true
        defer { isMeasuringTrash = false }
        let trash = AgentState.trashURL()
        let walker = FileWalker(fileSystem: LocalFileSystem())
        do {
            trashBytes = try await walker.directorySize(trash)
        } catch {
            trashBytes = 0   // no Trash folder yet, or unreadable: show empty rather than stale
        }
    }

    static func trashURL() -> URL {
        if let url = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash", directoryHint: .isDirectory)
    }

    // MARK: Actions

    func freeUpRAM() {
        openMainApp(route: Route.freeRAM)
    }

    func runSmartCare() {
        openMainApp(route: Route.smartCare)
    }

    func emptyTrash() {
        openMainApp(route: Route.emptyTrash)
    }

    func openMainApp() {
        openMainApp(route: Route.root)
    }

    func startScreenCleaning() {
        ScreenCleaningController.shared.begin()
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    /// Opens a `maccleaner://` route. If Launch Services does not know the
    /// scheme yet, launches the main app by bundle id (or by walking up from
    /// `Contents/Library/LoginItems/` to the enclosing bundle) so the button
    /// never silently does nothing.
    private func openMainApp(route: String) {
        guard let url = URL(string: route) else { return }
        if NSWorkspace.shared.open(url) { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentState.mainAppBundleIdentifier)
            ?? AgentState.enclosingAppURL() {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, _ in }
        }
    }

    /// `…/Mac Cleaner.app/Contents/Library/LoginItems/MacCleanerMenu.app` → `…/Mac Cleaner.app`.
    static func enclosingAppURL(agentBundleURL: URL = Bundle.main.bundleURL) -> URL? {
        let candidate = agentBundleURL
            .deletingLastPathComponent()   // LoginItems
            .deletingLastPathComponent()   // Library
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // Mac Cleaner.app
        return candidate.pathExtension == "app" ? candidate : nil
    }
}
