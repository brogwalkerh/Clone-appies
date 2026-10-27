import AppKit
import CleanerCore
import Foundation
import Observation
import ProtectionModule
import UIKitBridge
import UserNotifications

/// Everything the popover observes. Owns the `SystemStatsSampler` task, the
/// periodic Trash measurement and the FSEvents `ProtectionMonitor`; every
/// action that needs the privileged helper or a scan is delegated to the main
/// app through the `maccleaner://` scheme, because the agent deliberately has
/// no helper access (ADR 0002). The monitor lives here, not in the main app,
/// so it keeps watching after the main window closes (CONTRACTS.md M4).
@MainActor
@Observable
final class AgentState {
    enum Route {
        static let root = "maccleaner://"
        static let smartCare = "maccleaner://smart-care"
        static let freeRAM = "maccleaner://performance?task=maintenance.freeRAM"
        static let emptyTrash = "maccleaner://cleanup?scanner=cleanup.trash"
        static let protection = "maccleaner://protection"
    }

    /// Keys shared with the main app through the `com.example.maccleaner.shared`
    /// suite (mirrors `MenuAgentSettings` in App/Modules/MenuApp).
    enum SharedSettings {
        static let suiteName = "com.example.maccleaner.shared"
        /// Whether the Protection Monitor runs. Absent means on.
        static let monitorEnabledKey = "monitor.enabled"
        /// Written by the agent, read by the app's Protection › Monitor tab.
        /// String literals mirror `MenuAgentSettings.Key.monitorLastEvent` /
        /// `.monitorThreatCount` in App/Modules/MenuApp/MenuAppView.swift (the
        /// agent target cannot import App code).
        static let monitorLastEventKey = "monitor.lastEvent"
        static let monitorThreatCountKey = "monitor.threatCount"

        // UserDefaults is thread-safe; the constant itself never mutates.
        nonisolated(unsafe) static let store: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard

        static func isMonitorEnabled() -> Bool {
            store.object(forKey: monitorEnabledKey) as? Bool ?? true
        }
    }

    /// What the popover's Protection Monitor row shows.
    enum MonitorState: Sendable, Hashable {
        case off
        case running(scanned: Int)
        case threats(count: Int, latest: Threat)
    }

    /// Bundle id of the main app, used to launch it when the URL scheme is not
    /// registered yet (first run before Launch Services has seen the app).
    static let mainAppBundleIdentifier = "com.example.maccleaner"

    /// Where the main app's `SignatureUpdater` writes feed files; merged over
    /// the bundled starter set when present.
    nonisolated static let signatureDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.example.maccleaner/signatures", directoryHint: .isDirectory)

    /// Threats kept for the row and the deep link; older ones fall off.
    static let maxRememberedThreats = 50

    /// Latest host snapshot; nil until the first sampling interval elapses.
    private(set) var stats: SystemStats?
    /// Size of `~/.Trash`; nil while the first measurement runs.
    private(set) var trashBytes: Int64?
    private(set) var isMeasuringTrash = false

    private(set) var monitorState: MonitorState = .off
    /// Most recent first, bounded by `maxRememberedThreats`.
    private(set) var recentThreats: [Threat] = []
    /// Why the monitor last stopped on its own (FSEvents failure); nil otherwise.
    private(set) var monitorError: String?

    var isScreenCleaningActive: Bool { ScreenCleaningController.shared.isActive }

    /// Persisted in the shared suite; flipping it starts or stops the monitor.
    var isMonitorEnabled: Bool {
        get { SharedSettings.isMonitorEnabled() }
        set {
            SharedSettings.store.set(newValue, forKey: SharedSettings.monitorEnabledKey)
            if newValue { startMonitor() } else { stopMonitor() }
        }
    }

    @ObservationIgnored private let sampler: SystemStatsSampler
    @ObservationIgnored private var samplerTask: Task<Void, Never>?
    @ObservationIgnored private var trashTask: Task<Void, Never>?
    @ObservationIgnored private let trashRefreshInterval: Duration = .seconds(60)

    @ObservationIgnored private var monitor: ProtectionMonitor?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var scannedCount = 0
    /// Cumulative threats since the monitor started; mirrored to the shared suite.
    @ObservationIgnored private var threatCount = 0
    @ObservationIgnored private var lastEventWrite: ContinuousClock.Instant?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var hasRequestedNotificationAuthorization = false

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
        if SharedSettings.isMonitorEnabled() {
            startMonitor()
        }
    }

    func stop() {
        samplerTask?.cancel()
        trashTask?.cancel()
        samplerTask = nil
        trashTask = nil
        stopMonitor()
    }

    // MARK: Protection Monitor

    /// Builds the signature database off the main actor (bundled starter plus
    /// any feed files on disk), then starts the monitor and consumes its stream.
    func startMonitor() {
        guard monitorTask == nil else { return }
        monitorError = nil
        scannedCount = 0
        threatCount = 0
        lastEventWrite = nil
        SharedSettings.store.set(0, forKey: SharedSettings.monitorThreatCountKey)
        monitorState = .running(scanned: 0)
        monitorTask = Task { [weak self] in
            let database = await Task.detached(priority: .utility) {
                AgentState.loadSignatureDatabase()
            }.value
            guard let self, !Task.isCancelled else { return }
            let monitor = ProtectionMonitor(database: database, verifier: SecCodeSignatureVerifier())
            self.monitor = monitor
            let events = await monitor.start()
            for await event in events {
                self.handle(event)
            }
        }
    }

    func stopMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
        if let monitor {
            Task { await monitor.stop() }
        }
        monitor = nil
        monitorState = .off
    }

    nonisolated static func loadSignatureDatabase() -> SignatureDatabase {
        var database = SignatureDatabase.bundledStarter()
        let fileSystem = LocalFileSystem()
        if fileSystem.exists(signatureDirectory) {
            // A corrupt feed file must not take the bundled set down with it.
            try? database.load(contentsOf: signatureDirectory, fileSystem: fileSystem)
        }
        return database
    }

    private func handle(_ event: ProtectionEvent) {
        switch event {
        case .started:
            monitorState = .running(scanned: scannedCount)
            requestNotificationAuthorizationIfNeeded()
        case .scanned:
            scannedCount += 1
            recordLastEvent()
            if case .running = monitorState {
                monitorState = .running(scanned: scannedCount)
            }
        case .threat(let threat):
            threatCount += 1
            SharedSettings.store.set(threatCount, forKey: SharedSettings.monitorThreatCountKey)
            recordLastEvent()
            recentThreats.insert(threat, at: 0)
            if recentThreats.count > AgentState.maxRememberedThreats {
                recentThreats.removeLast(recentThreats.count - AgentState.maxRememberedThreats)
            }
            monitorState = .threats(count: recentThreats.count, latest: threat)
            postThreatNotification(threat)
        case .stopped(let reason):
            monitorTask = nil
            monitor = nil
            monitorState = .off
            if reason != "stopped", reason != "restarted" {
                monitorError = reason
            }
        }
    }

    /// Writes `monitor.lastEvent` at most once per second so a download burst
    /// does not hammer cfprefsd.
    private func recordLastEvent() {
        let now = clock.now
        if let last = lastEventWrite, now - last < .seconds(1) { return }
        lastEventWrite = now
        SharedSettings.store.set(Date(), forKey: SharedSettings.monitorLastEventKey)
    }

    /// Clears the threat badge (the main app's Protection screen is the
    /// authority for what has been quarantined).
    func acknowledgeThreats() {
        recentThreats.removeAll()
        if case .threats = monitorState {
            monitorState = .running(scanned: scannedCount)
        }
    }

    // MARK: Notifications

    private func requestNotificationAuthorizationIfNeeded() {
        guard !hasRequestedNotificationAuthorization else { return }
        hasRequestedNotificationAuthorization = true
        Task.detached(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// `UNNotificationRequest` is not `Sendable`, so only strings cross into
    /// the task and the request is assembled there.
    private func postThreatNotification(_ threat: Threat) {
        let identifier = threat.id.uuidString
        let body = AgentState.notificationBody(for: threat)
        let path = threat.path.path(percentEncoded: false)
        let route = Route.protection
        Task.detached(priority: .utility) {
            let content = UNMutableNotificationContent()
            content.title = "Threat detected"
            content.body = body
            content.sound = .default
            content.userInfo = ["route": route, "path": path]
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated static func notificationBody(for threat: Threat) -> String {
        "\(threat.name) — \(threat.path.lastPathComponent)"
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

    func openProtection() {
        openMainApp(route: Route.protection)
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
