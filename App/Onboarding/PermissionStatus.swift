import AppKit
import ApplicationServices
import Foundation
import ServiceManagement
import UserNotifications

/// Result of one permission probe.
enum PermissionState: Sendable, Hashable {
    case unknown
    case notDetermined
    case granted
    case denied

    var isGranted: Bool { self == .granted }

    var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .notDetermined: return "Not requested"
        case .granted: return "Granted"
        case .denied: return "Not granted"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .notDetermined: return "circle.dashed"
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }
}

/// The permissions the onboarding flow walks through (PLAN.md §6).
enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case fullDiskAccess
    case accessibility
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        }
    }

    var detail: String {
        switch self {
        case .fullDiskAccess:
            return "Lets the app see caches, Mail attachments, and other apps' containers. Required for Cleanup."
        case .accessibility:
            return "Needed by Screen Cleaning Mode to swallow keyboard and trackpad input while you wipe the display."
        case .notifications:
            return "Scan reminders and cleanup results. Optional."
        }
    }

    var systemImage: String {
        switch self {
        case .fullDiskAccess: return "internaldrive"
        case .accessibility: return "accessibility"
        case .notifications: return "bell.badge"
        }
    }

    /// Deep link into System Settings › Privacy & Security.
    var settingsURL: URL? {
        switch self {
        case .fullDiskAccess:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
    }
}

/// Snapshot of all permission states at one instant.
struct PermissionSnapshot: Sendable, Hashable {
    var fullDiskAccess: PermissionState
    var accessibility: PermissionState
    var notifications: PermissionState

    static let unknown = PermissionSnapshot(fullDiskAccess: .unknown, accessibility: .unknown, notifications: .unknown)

    subscript(kind: PermissionKind) -> PermissionState {
        switch kind {
        case .fullDiskAccess: return fullDiskAccess
        case .accessibility: return accessibility
        case .notifications: return notifications
        }
    }

    /// True when the permissions the core modules need are granted.
    var coreGranted: Bool { fullDiskAccess.isGranted }
}

/// Probes each permission. Stateless; safe to call from any isolation.
enum PermissionChecker {
    static func snapshot() async -> PermissionSnapshot {
        PermissionSnapshot(
            fullDiskAccess: fullDiskAccess(),
            accessibility: accessibility(),
            notifications: await notifications()
        )
    }

    /// Heuristic: TCC-protected folders in ~/Library are unreadable (EPERM,
    /// `NSFileReadNoPermissionError`) without Full Disk Access. If neither
    /// folder exists the result is `.unknown` rather than a false positive.
    static func fullDiskAccess() -> PermissionState {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Safari", isDirectory: true)
        ]
        var sawMissing = false
        for probe in probes {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: probe.path)
                return .granted
            } catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain {
                    switch error.code {
                    case NSFileReadNoPermissionError:
                        return .denied
                    case NSFileReadNoSuchFileError:
                        sawMissing = true
                        continue
                    default:
                        break
                    }
                }
                if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) {
                    return .denied
                }
                if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
                    sawMissing = true
                    continue
                }
                return .denied
            }
        }
        return sawMissing ? .unknown : .denied
    }

    static func accessibility() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    static func notifications() async -> PermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }

    /// Shows the system notification prompt. Returns the resulting state.
    static func requestNotifications() async -> PermissionState {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }

    /// Prompts for Accessibility (shows the system dialog once) then opens Settings.
    @MainActor
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openSystemSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Registers and inspects the privileged helper daemon (PLAN.md §5, Privilege).
/// The plist lives in the app bundle's `Contents/Library/LaunchDaemons`; infra
/// owns its name and contents, so this type only references it.
@MainActor
@Observable
final class HelperInstaller {
    /// Must match the plist infra ships. TODO(infra): confirm final label.
    static let daemonPlistName = "com.example.maccleaner.helper.plist"

    private(set) var status: SMAppService.Status
    private(set) var lastError: String?

    private var service: SMAppService { .daemon(plistName: HelperInstaller.daemonPlistName) }

    init() {
        status = SMAppService.daemon(plistName: HelperInstaller.daemonPlistName).status
    }

    var statusLabel: String {
        switch status {
        case .notRegistered: return "Not installed"
        case .enabled: return "Installed and enabled"
        case .requiresApproval: return "Waiting for approval in System Settings › Login Items"
        case .notFound: return "Helper not found in app bundle"
        @unknown default: return "Unknown"
        }
    }

    var isInstalled: Bool { status == .enabled }

    func refresh() {
        status = service.status
    }

    /// Registers the daemon. macOS asks the user to approve it in Login Items.
    func install() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func uninstall() async {
        do {
            try await service.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Launch-at-login for the main app via `SMAppService.mainApp` (Settings › General).
enum LaunchAtLogin {
    @MainActor
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @MainActor
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
