import AppKit
import SwiftUI
import CleanerCore
import DesignSystem

/// Settings window: General, Ignore List, Scheduler, Advanced (PLAN.md §3.12).
/// Protection, Updates and Privacy tabs arrive with their modules.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                GeneralSettingsView()
            }
            Tab("Ignore List", systemImage: "eye.slash") {
                IgnoreListSettingsView()
            }
            Tab("Scheduler", systemImage: "calendar.badge.clock") {
                SchedulerSettingsView()
            }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                AdvancedSettingsView()
            }
        }
        .frame(width: 600, height: 440)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(SettingsStore.Key.removalMode) private var removalModeRaw = RemovalMode.trash.rawValue
    @AppStorage(SettingsStore.Key.showMenuBarAgent) private var showMenuBarAgent = false

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != LaunchAtLogin.isEnabled else { return }
                        do {
                            try LaunchAtLogin.set(enabled)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show menu bar agent", isOn: $showMenuBarAgent)
                Text("The menu bar agent (storage, RAM, CPU, Protection Monitor, Screen Cleaning Mode) ships in M3. This setting is stored now and takes effect then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Removal") {
                Picker("When cleaning", selection: $removalModeRaw) {
                    Text("Move items to the Trash (recommended)").tag(RemovalMode.trash.rawValue)
                    Text("Delete items permanently").tag(RemovalMode.permanent.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text("Trash-first keeps \"Undo last cleanup\" available until you empty the Trash. Permanent deletion is immediate and cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ignore list

struct IgnoreListSettingsView: View {
    @State private var paths: [String] = SettingsStore.ignoredPaths()
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scanners never report anything under these locations.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(paths, id: \.self, selection: $selection) { path in
                Label {
                    Text(path)
                        .truncationMode(.middle)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "folder")
                }
            }
            .listStyle(.bordered)
            .overlay {
                if paths.isEmpty {
                    ContentUnavailableView("No ignored locations",
                                           systemImage: "eye.slash",
                                           description: Text("Add folders or files that cleanups should leave alone."))
                }
            }

            HStack {
                Button("Add…", systemImage: "plus") { add() }
                Button("Remove", systemImage: "minus") { removeSelected() }
                    .disabled(selection.isEmpty)
                Spacer()
                Text("\(paths.count) ignored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
        }
        .padding(20)
        .onChange(of: paths) { _, newValue in
            SettingsStore.setIgnoredPaths(newValue)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            if !paths.contains(path) {
                paths.append(path)
            }
        }
    }

    private func removeSelected() {
        paths.removeAll { selection.contains($0) }
        selection.removeAll()
    }
}

// MARK: - Scheduler

struct SchedulerSettingsView: View {
    @State private var frequency = "weekly"

    var body: some View {
        Form {
            Section("Scheduled scans") {
                Picker("Run Smart Care", selection: $frequency) {
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                    Text("Monthly").tag("monthly")
                }
                .disabled(true)
                Toggle("Notify me when a scheduled scan finds something", isOn: .constant(true))
                    .disabled(true)
            }
            Section {
                EmptyState.comingSoon(feature: "Scheduler",
                                      milestone: "M5",
                                      systemImage: "calendar.badge.clock",
                                      message: "Scheduled scans, reminders and scan history arrive with the persistence layer in M5.")
                    .frame(height: 160)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var helper = HelperInstaller()
    @State private var confirmReset = false
    @State private var isWorking = false

    var body: some View {
        Form {
            Section("Privileged helper") {
                LabeledContent("Status", value: helper.statusLabel)
                if let error = helper.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Install") { helper.install() }
                        .disabled(helper.isInstalled || isWorking)
                    Button("Uninstall") {
                        isWorking = true
                        Task {
                            await helper.uninstall()
                            isWorking = false
                        }
                    }
                    .disabled(!helper.isInstalled || isWorking)
                    if helper.status == .requiresApproval {
                        Button("Open Login Items Settings") { HelperInstaller.openLoginItemsSettings() }
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { helper.refresh() }
                        .labelStyle(.iconOnly)
                }
            }

            Section("Reset") {
                Button("Show Onboarding Again") {
                    appState.resetOnboarding()
                }
                Button("Reset All Settings…", role: .destructive) {
                    confirmReset = true
                }
                Text("Clears preferences, the ignore list and pinned tools. Scan results and the Trash are not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { helper.refresh() }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                SettingsStore.resetAll()
                appState.resetOnboarding()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
