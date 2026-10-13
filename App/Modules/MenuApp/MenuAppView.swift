import AppKit
import ServiceManagement
import SwiftUI
import DesignSystem
import UIKitBridge

/// Settings for the menu bar login-item agent (PLAN.md §3.10, CONTRACTS.md "M3 — MenuAgent").
///
/// The agent is a separate `LSUIElement` app embedded at
/// `Contents/Library/LoginItems` and registered with `SMAppService.loginItem`.
/// Which pills it shows is stored in the shared suite
/// `com.example.maccleaner.shared`, which the agent reads through
/// `UserDefaults(suiteName:)`; keys are in `MenuAgentSettings.Key`.
struct MenuAppView: View {
    @State private var agent = MenuAgentController()

    @AppStorage(MenuAgentSettings.Key.showCPU, store: MenuAgentSettings.store) private var showCPU = true
    @AppStorage(MenuAgentSettings.Key.showMemory, store: MenuAgentSettings.store) private var showMemory = true
    @AppStorage(MenuAgentSettings.Key.showDisk, store: MenuAgentSettings.store) private var showDisk = true
    @AppStorage(MenuAgentSettings.Key.showBattery, store: MenuAgentSettings.store) private var showBattery = true
    @AppStorage(MenuAgentSettings.Key.showNetwork, store: MenuAgentSettings.store) private var showNetwork = true
    @AppStorage(MenuAgentSettings.Key.showTrash, store: MenuAgentSettings.store) private var showTrash = true
    @AppStorage(MenuAgentSettings.Key.showProtectionMonitor, store: MenuAgentSettings.store) private var showProtection = true
    @AppStorage(SettingsStore.Key.showMenuBarAgent) private var showMenuBarAgent = false

    @State private var screenCleaningNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusCard
                pillsCard
                screenCleaningCard
            }
            .padding(32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Menu")
        .navigationSubtitle(agent.statusLabel)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionBar {
                HStack(spacing: 12) {
                    if agent.status == .requiresApproval {
                        Button("Open Login Items") { MenuAgentController.openLoginItemsSettings() }
                            .buttonStyle(.glass)
                    }
                    Button("Launch Now") { agent.launchNow() }
                        .buttonStyle(.glass)
                        .disabled(agent.isWorking)
                }
            } content: {
                PrimaryActionButton(agent.isEnabled ? "Disable Menu Bar Agent" : "Enable Menu Bar Agent",
                                    isLoading: agent.isWorking) {
                    Task { await agent.setEnabled(!agent.isEnabled) }
                    showMenuBarAgent = !agent.isEnabled
                }
            }
        }
        .task { agent.refresh() }
        .messageAlert("Menu Bar Agent", message: $agent.lastError)
        .messageAlert("Screen Cleaning Mode", message: $screenCleaningNotice)
    }

    // MARK: Cards

    private var statusCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: agent.isEnabled ? "menubar.dock.rectangle.badge.record" : "menubar.rectangle")
                    .font(.title)
                    .foregroundStyle(agent.isEnabled ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Menu bar agent")
                        .font(.headline)
                    Text(agent.statusLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Shows live stats in the menu bar and keeps running after this window closes. It opens Smart Care and Performance here through maccleaner:// links.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Label(agent.isEnabled ? "Enabled" : "Off", systemImage: agent.isEnabled ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(agent.isEnabled ? Color.green : Color.secondary)
            }
        }
    }

    private var pillsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Pills in the popover", systemImage: "capsule")
                    .font(.headline)
                Text("Pick what the agent shows. Changes apply the next time the popover opens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    pillToggle("CPU", systemImage: "cpu", isOn: $showCPU)
                    pillToggle("RAM with Free Up", systemImage: "memorychip", isOn: $showMemory)
                    pillToggle("Disk and purgeable space", systemImage: "internaldrive", isOn: $showDisk)
                    pillToggle("Battery health and cycles", systemImage: "battery.75percent", isOn: $showBattery)
                    pillToggle("Network up / down", systemImage: "network", isOn: $showNetwork)
                    pillToggle("Trash size", systemImage: "trash", isOn: $showTrash)
                    pillToggle("Protection Monitor", systemImage: "shield", isOn: $showProtection)
                }
            }
        }
    }

    private func pillToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var screenCleaningCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Cleaning Mode")
                        .font(.headline)
                    Text("Blacks out every display and ignores keyboard and trackpad input for two minutes so you can wipe the screen. Hold ⌘ for two seconds to exit early. Needs Accessibility.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Try Screen Cleaning Mode") {
                    if PermissionChecker.accessibility() != .granted {
                        screenCleaningNotice = "Accessibility is off, so keys and clicks would still reach your apps. The mode starts anyway with an explanation; grant Accessibility in System Settings for the full effect."
                    }
                    ScreenCleaningController.shared.begin()
                }
                .buttonStyle(.glassProminent)
                .disabled(ScreenCleaningController.shared.isActive)
            }
        }
    }
}

// MARK: - Shared settings suite

/// Keys the agent and the main app share through `com.example.maccleaner.shared`.
enum MenuAgentSettings {
    static let suiteName = "com.example.maccleaner.shared"

    /// Falls back to `.standard` only if the suite cannot be created (never in practice).
    // UserDefaults is thread-safe; the constant itself never mutates.
    nonisolated(unsafe) static let store: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard

    enum Key {
        static let showCPU = "menu.pills.cpu"
        static let showMemory = "menu.pills.memory"
        static let showDisk = "menu.pills.disk"
        static let showBattery = "menu.pills.battery"
        static let showNetwork = "menu.pills.network"
        static let showTrash = "menu.pills.trash"
        static let showProtectionMonitor = "menu.pills.protectionMonitor"
    }
}

// MARK: - Agent registration

/// Registers, unregisters and launches the embedded menu bar agent.
@MainActor
@Observable
final class MenuAgentController {
    static let loginItemIdentifier = "com.example.maccleaner.MenuAgent"

    private(set) var status: SMAppService.Status
    private(set) var isWorking = false
    var lastError: String?

    private var service: SMAppService { .loginItem(identifier: MenuAgentController.loginItemIdentifier) }

    init() {
        status = SMAppService.loginItem(identifier: MenuAgentController.loginItemIdentifier).status
    }

    var isEnabled: Bool { status == .enabled }

    var statusLabel: String {
        switch status {
        case .notRegistered: return "Not enabled"
        case .enabled: return "Enabled; starts at login"
        case .requiresApproval: return "Waiting for approval in System Settings › Login Items"
        case .notFound: return "Agent not found in the app bundle"
        @unknown default: return "Unknown"
        }
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            if enabled {
                try service.register()
            } else {
                try await service.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Opens the embedded agent without waiting for the next login.
    func launchNow() {
        guard let url = MenuAgentController.agentBundleURL() else {
            lastError = "The menu bar agent is not embedded in this build (Contents/Library/LoginItems)."
            return
        }
        isWorking = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        Task {
            defer { isWorking = false }
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// `Contents/Library/LoginItems/MacCleanerMenu.app` (PRODUCT_NAME in project.yml),
    /// falling back to the first `.app` in that folder.
    /// TODO(macOS27): confirm SMAppService.loginItem still expects the agent under Contents/Library/LoginItems.
    static func agentBundleURL() -> URL? {
        let loginItems = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        let preferred = loginItems.appendingPathComponent("MacCleanerMenu.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: preferred.path(percentEncoded: false)) {
            return preferred
        }
        let candidates = (try? FileManager.default.contentsOfDirectory(at: loginItems, includingPropertiesForKeys: nil)) ?? []
        return candidates.first { $0.pathExtension == "app" }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

#Preview {
    MenuAppView()
        .environment(AppState())
        .frame(width: 1000, height: 760)
}
