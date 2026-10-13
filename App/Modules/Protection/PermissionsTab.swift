import AppKit
import SwiftUI
import Observation
import CleanerCore
import DesignSystem
import ProtectionModule
import UIKitBridge

/// Loads TCC grants through `TCCPermissionsReader` (needs Full Disk Access) and
/// groups them by service. Owned by `ProtectionView` so a reload survives tab switches.
@MainActor
@Observable
final class PermissionsStore {
    enum State: Hashable, Sendable {
        case idle
        case loading
        case loaded
        /// The reader could not open the TCC database (almost always: no Full Disk Access).
        case needsFullDiskAccess(String)
        /// The database opened but the query failed (schema drift, corruption).
        case failed(String)
    }

    struct ServiceGroup: Identifiable, Hashable, Sendable {
        let service: PrivacyService
        let grants: [PermissionGrant]

        var id: String { service.rawValue }
        var grantedCount: Int { grants.lazy.filter(\.granted).count }
    }

    private(set) var state: State = .idle
    private(set) var grants: [PermissionGrant] = []
    private(set) var lastLoadedAt: Date?

    var isLoading: Bool { state == .loading }

    /// `PrivacyService.allCases` order, services without grants omitted; granted first, then by name.
    var groups: [ServiceGroup] {
        let byService = Dictionary(grouping: grants, by: \.service)
        return PrivacyService.allCases.compactMap { service in
            guard let list = byService[service], !list.isEmpty else { return nil }
            let sorted = list.sorted { lhs, rhs in
                if lhs.granted != rhs.granted { return lhs.granted }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return ServiceGroup(service: service, grants: sorted)
        }
    }

    func refreshIfNeeded() async {
        guard state == .idle else { return }
        await refresh()
    }

    func refresh() async {
        guard state != .loading else { return }
        state = .loading
        let reader = TCCPermissionsReader()
        do {
            let list = try await reader.grants()
            // The reader returns `[]` rather than throwing when TCC.db cannot be
            // opened; `lastError` says whether Full Disk Access would fix it.
            if let error = await reader.lastError, list.isEmpty {
                grants = []
                state = error.needsFullDiskAccess ? .needsFullDiskAccess(error.description) : .failed(error.description)
                return
            }
            grants = list
            lastLoadedAt = .now
            state = .loaded
        } catch {
            grants = []
            state = .failed(error.localizedDescription)
        }
    }
}

/// Protection › Permissions: apps holding each privacy service, with a deep link
/// into the matching System Settings pane (PLAN.md §3.3).
struct PermissionsTab: View {
    let store: PermissionsStore

    var body: some View {
        switch store.state {
        case .idle, .loading where store.grants.isEmpty:
            EmptyState.scanning("Reading app permissions…",
                                message: "Looks at the user and system TCC databases.")

        case .needsFullDiskAccess(let message):
            EmptyState(title: "Full Disk Access Required",
                       message: "The permissions database can only be read with Full Disk Access. \(message)",
                       style: .symbol("lock.shield"),
                       actionTitle: "Open Full Disk Access Settings") {
                PermissionChecker.openSystemSettings(for: .fullDiskAccess)
            }

        case .failed(let message):
            EmptyState(title: "Permissions Could Not Be Read",
                       message: message,
                       style: .symbol("exclamationmark.triangle"),
                       actionTitle: "Try Again") {
                Task { await store.refresh() }
            }

        case .loaded where store.grants.isEmpty:
            EmptyState.nothingFound("No Permission Grants",
                                    message: "No app has asked for the camera, microphone, Full Disk Access, Accessibility, Screen Recording or the other services yet.",
                                    actionTitle: "Refresh") {
                Task { await store.refresh() }
            }

        default:
            List {
                ForEach(store.groups) { group in
                    Section {
                        ForEach(group.grants) { grant in
                            PermissionGrantRow(grant: grant)
                        }
                    } header: {
                        HStack(spacing: 10) {
                            Label(group.service.title, systemImage: group.service.systemImage)
                                .font(.headline)
                            Text("\(group.grantedCount) of \(group.grants.count) granted")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Manage in System Settings") {
                                group.service.openSystemSettings()
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    } footer: {
                        Text(group.service.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }
}

struct PermissionGrantRow: View {
    let grant: PermissionGrant

    var body: some View {
        HStack(spacing: 12) {
            PermissionAppIcon(clientID: grant.clientID)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(grant.displayName)
                    .lineLimit(1)
                Text(grant.clientID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let date = grant.lastModified {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Label(grant.granted ? "Allowed" : "Denied",
                  systemImage: grant.granted ? "checkmark.circle.fill" : "xmark.circle")
                .font(.callout)
                .foregroundStyle(grant.granted ? Color.green : Color.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(grant.displayName), \(grant.granted ? "allowed" : "denied")"))
    }
}

/// Finder icon for a TCC client: a bundle id resolved through Launch Services,
/// or an absolute executable path. Falls back to a generic symbol.
struct PermissionAppIcon: View {
    let clientID: String

    var body: some View {
        if let url = PermissionAppIcon.url(for: clientID) {
            Image(nsImage: AppIconProvider.icon(for: url))
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @MainActor
    static func url(for clientID: String) -> URL? {
        if clientID.hasPrefix("/") {
            let url = URL(fileURLWithPath: clientID)
            return FileManager.default.fileExists(atPath: clientID) ? url : nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: clientID)
    }
}

extension PermissionGrant {
    /// App name when the reader resolved one, else the bundle id or path's last component.
    var displayName: String {
        if let clientName, !clientName.isEmpty { return clientName }
        if clientID.hasPrefix("/") { return (clientID as NSString).lastPathComponent }
        return clientID
    }
}

extension PrivacyService {
    var title: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .fullDiskAccess: return "Full Disk Access"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .location: return "Location Services"
        case .contacts: return "Contacts"
        case .calendars: return "Calendars"
        case .photos: return "Photos"
        case .inputMonitoring: return "Input Monitoring"
        case .automation: return "Automation"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "mic"
        case .fullDiskAccess: return "internaldrive"
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .location: return "location"
        case .contacts: return "person.crop.circle"
        case .calendars: return "calendar"
        case .photos: return "photo.on.rectangle"
        case .inputMonitoring: return "keyboard"
        case .automation: return "gearshape.2"
        }
    }

    var explanation: String {
        switch self {
        case .camera: return "Apps that can use the built-in or external cameras."
        case .microphone: return "Apps that can record audio from the microphone."
        case .fullDiskAccess: return "Apps that can read every file, including Mail, Messages, Safari data and other apps' containers."
        case .accessibility: return "Apps that can control your Mac: read the screen, press keys and move the pointer."
        case .screenRecording: return "Apps that can capture the contents of the screen."
        case .location: return "Apps that can use your Mac's location."
        case .contacts: return "Apps that can read your contacts."
        case .calendars: return "Apps that can read and change your calendars."
        case .photos: return "Apps that can read your Photos library."
        case .inputMonitoring: return "Apps that can watch keyboard input even while another app is in front."
        case .automation: return "Apps allowed to control other apps with Apple Events (AppleScript)."
        }
    }

    /// Anchor for `x-apple.systempreferences:com.apple.preference.security?Privacy_<X>`.
    var settingsAnchor: String {
        switch self {
        case .camera: return "Privacy_Camera"
        case .microphone: return "Privacy_Microphone"
        case .fullDiskAccess: return "Privacy_AllFiles"
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .location: return "Privacy_LocationServices"
        case .contacts: return "Privacy_Contacts"
        case .calendars: return "Privacy_Calendars"
        case .photos: return "Privacy_Photos"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .automation: return "Privacy_Automation"
        }
    }

    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
    }

    // TODO(macOS27): confirm the `Privacy_*` anchors still select the matching pane in
    // System Settings › Privacy & Security on macOS 27; they are unchanged through macOS 26.
    @MainActor
    func openSystemSettings() {
        guard let url = settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    PermissionsTab(store: PermissionsStore())
        .frame(width: 1000, height: 700)
}
