import SwiftUI
import CleanerCore
import DesignSystem

/// The main window: edge-to-edge sidebar on the left, module detail on the right,
/// bell + search in the toolbar. Each module supplies its own `BottomActionBar`.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appearsActive) private var appearsActive

    @State private var searchText = ""
    @State private var showNotifications = false
    @State private var showOnboarding = false

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            sidebar(selection: $appState.selection)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    permissionBanner
                }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ToolbarBell(unreadCount: appState.unreadCount) {
                    showNotifications.toggle()
                }
                .popover(isPresented: $showNotifications, arrowEdge: .bottom) {
                    NotificationListView()
                        .environment(appState)
                }
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                appState.completeOnboarding()
                showOnboarding = false
            }
            .environment(appState)
        }
        .task {
            await appState.refreshPermissions()
            if !appState.hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .onChange(of: appearsActive) { _, active in
            // Re-check permissions whenever the window becomes active again, since
            // the user may have toggled something in System Settings.
            if active {
                Task { await appState.refreshPermissions() }
            }
        }
    }

    // MARK: Sidebar

    private func sidebar(selection: Binding<SidebarItem?>) -> some View {
        List(selection: selection) {
            Section {
                sidebarRow(.smartCare)
            }

            if !appState.pinnedTools.isEmpty {
                Section("My Tools") {
                    ForEach(appState.pinnedTools) { item in
                        sidebarRow(item)
                    }
                    .onMove { source, destination in
                        appState.movePins(fromOffsets: source, toOffset: destination)
                    }
                }
            }

            Section("Modules") {
                ForEach(SidebarItem.items(in: .modules)) { item in
                    sidebarRow(item)
                }
            }

            Section("More") {
                ForEach(SidebarItem.items(in: .more)) { item in
                    sidebarRow(item)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Label {
            Text(item.title)
        } icon: {
            Image(systemName: item.systemImage)
                .moduleForeground(item.tint)
        }
        .tag(item)
        .contextMenu {
            if item.isPinnable {
                Button(appState.isPinned(item) ? "Unpin from My Tools" : "Pin to My Tools") {
                    appState.togglePin(item)
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch appState.selection ?? .smartCare {
        case .smartCare: SmartCareView()
        case .cleanup: CleanupView()
        case .protection: ProtectionView()
        case .performance: PerformanceView()
        case .applications: ApplicationsView()
        case .myClutter: MyClutterView()
        case .cloudCleanup: CloudCleanupView()
        case .emailCleanup: EmailCleanupView()
        case .spaceLens: SpaceLensView()
        case .myActivity: MyActivityView()
        case .menuApp: MenuAppView()
        }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        if appState.hasCompletedOnboarding, appState.permissions.fullDiskAccess == .denied {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                Text("Full Disk Access is off. Cleanup and Space Lens can only see part of your Mac.")
                    .font(.callout)
                Spacer()
                Button("Open System Settings") {
                    PermissionChecker.openSystemSettings(for: .fullDiskAccess)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

// MARK: - Bottom action bar

/// Fixed bar at the bottom of a module hosting the single primary action.
/// Modules attach it with `.safeAreaInset(edge: .bottom) { BottomActionBar { … } }`.
struct BottomActionBar<Leading: View, Content: View>: View {
    private let leading: Leading
    private let content: Content

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder content: () -> Content) {
        self.leading = leading()
        self.content = content()
    }

    init(@ViewBuilder content: () -> Content) where Leading == EmptyView {
        self.leading = EmptyView()
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer {
            HStack {
                leading
                Spacer()
                content
                Spacer()
                // Keeps the primary button centered when there is a leading item.
                leading.hidden()
            }
            .padding(.horizontal, 24)
            .frame(height: Metrics.bottomBarHeight)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Notification popover

struct NotificationListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer()
                if appState.unreadCount > 0 {
                    Button("Mark All Read") { appState.markAllRead() }
                        .controlSize(.small)
                }
                if !appState.notifications.isEmpty {
                    Button("Clear") { appState.clearNotifications() }
                        .controlSize(.small)
                }
            }
            .padding(12)
            Divider()
            if appState.notifications.isEmpty {
                ContentUnavailableView("No notifications",
                                       systemImage: "bell.slash",
                                       description: Text("Scan reminders and cleanup results appear here."))
                    .frame(height: 180)
            } else {
                List(appState.notifications) { note in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(note.isRead ? Color.clear : Color.accentColor)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title).font(.subheadline.weight(.semibold))
                            Text(note.message).font(.caption).foregroundStyle(.secondary)
                            Text(note.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
                .frame(height: 280)
            }
        }
        .frame(width: 340)
    }
}

#Preview {
    RootView()
        .environment(AppState())
        .frame(width: 1200, height: 800)
}
