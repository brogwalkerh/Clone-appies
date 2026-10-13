import SwiftUI
import DesignSystem

/// Shared scaffold for modules that ship in a later milestone (PLAN.md §7).
/// Keeps the navigation title and bottom bar so the shell feels complete.
/// Applications and My Clutter moved to `Modules/Applications` and
/// `Modules/MyClutter` in M2, Performance and Menu to `Modules/Performance` and
/// `Modules/MenuApp` in M3; Protection, Cloud and Email remain.
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

#Preview("Placeholders") {
    TabView {
        ProtectionView()
        CloudCleanupView()
        EmailCleanupView()
    }
    .frame(width: 900, height: 600)
}
