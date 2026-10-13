import SwiftUI
import DesignSystem

/// Shared scaffold for modules that ship in a later milestone (PLAN.md §7).
/// Keeps the navigation title and bottom bar so the shell feels complete.
struct ModulePlaceholder: View {
    let item: SidebarItem
    let summary: String

    var body: some View {
        EmptyState.comingSoon(feature: item.title,
                              milestone: item.pendingMilestone ?? "a later milestone",
                              systemImage: item.systemImage,
                              message: "\(summary) Coming in \(item.pendingMilestone ?? "a later milestone").")
            .navigationTitle(item.title)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomActionBar {
                    PrimaryActionButton("Scan", isEnabled: false) {}
                        .moduleTint(item.tint)
                }
            }
    }
}

struct ProtectionView: View {
    var body: some View {
        ModulePlaceholder(item: .protection,
                          summary: "Quick, Normal and Deep malware scans, privacy cleaners for browsers and chat apps, an app permissions review, and the real-time Protection Monitor.")
    }
}

struct PerformanceView: View {
    var body: some View {
        ModulePlaceholder(item: .performance,
                          summary: "Maintenance tasks (free RAM, flush DNS, reindex Spotlight, thin snapshots), login and background items, heavy consumers, and hung-app detection.")
    }
}

struct ApplicationsView: View {
    var body: some View {
        ModulePlaceholder(item: .applications,
                          summary: "Uninstaller with leftovers, orphaned-file cleanup, an updater for App Store, Sparkle and Homebrew apps, extensions, app reset, and stray installers.")
    }
}

struct MyClutterView: View {
    var body: some View {
        ModulePlaceholder(item: .myClutter,
                          summary: "Large and old files, duplicate detection with SHA-256, similar-image clustering via Vision, and Downloads triage.")
    }
}

struct CloudCleanupView: View {
    var body: some View {
        ModulePlaceholder(item: .cloudCleanup,
                          summary: "iCloud Drive local analysis plus Google Drive, OneDrive and Dropbox cleanup over their APIs.")
    }
}

struct EmailCleanupView: View {
    var body: some View {
        ModulePlaceholder(item: .emailCleanup,
                          summary: "Gmail newsletters, promotions, large attachments, one-click unsubscribe, and a subscription manager.")
    }
}

/// Preview of the menu bar popover that ships with the login-item agent in M3.
struct MenuAppView: View {
    var body: some View {
        VStack(spacing: 24) {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Menu bar agent preview", systemImage: "menubar.rectangle")
                        .font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        StatPill(systemImage: "internaldrive", value: "—", caption: "Storage free")
                        StatPill(systemImage: "memorychip", value: "—", caption: "RAM used")
                        StatPill(systemImage: "cpu", value: "—", caption: "CPU")
                        StatPill(systemImage: "battery.75percent", value: "—", caption: "Battery health")
                        StatPill(systemImage: "network", value: "—", caption: "Network")
                        StatPill(systemImage: "trash", value: "—", caption: "Trash size")
                    }
                    Text("Runs as a separate login item so it survives closing the main window. Includes Protection Monitor status, quick Smart Care, and Screen Cleaning Mode.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 560)

            EmptyState.comingSoon(feature: "Menu",
                                  milestone: SidebarItem.menuApp.pendingMilestone ?? "M3",
                                  systemImage: "menubar.rectangle",
                                  message: "The agent target, live stats and Screen Cleaning Mode arrive in M3.")
        }
        .padding(32)
        .navigationTitle("Menu")
    }
}

#Preview("Placeholders") {
    TabView {
        ProtectionView()
        PerformanceView()
        MenuAppView()
    }
    .frame(width: 900, height: 600)
}
