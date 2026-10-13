import SwiftUI
import DesignSystem

/// Three-step first launch: welcome → permissions → privileged helper (PLAN.md §4).
/// Presented as a sheet by `RootView` until `AppState.hasCompletedOnboarding`.
struct OnboardingView: View {
    enum Step: Int, CaseIterable, Hashable {
        case welcome, permissions, helper

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Permissions"
            case .helper: return "Helper"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Step
    @State private var helper = HelperInstaller()
    @State private var isRefreshing = false

    let onFinish: @MainActor () -> Void

    /// - Parameter initialStep: `.helper` lets modules reopen just the helper
    ///   install step after onboarding is done (Performance, deep links).
    init(initialStep: Step = .welcome, onFinish: @escaping @MainActor () -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .helper: helperStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(36)
            .animation(reduceMotion ? nil : .default, value: step)

            Divider()
            footer
        }
        .frame(width: 680, height: 560)
        .task { await refresh() }
        .onChange(of: step) { _, newStep in
            if newStep == .helper { helper.refresh() }
            if newStep == .permissions { Task { await refresh() } }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("Keep your Mac fast and tidy")
                .font(.largeTitle.weight(.bold))
            Text("Clean system junk, map your disk, uninstall apps completely, and keep an eye on performance. Nothing leaves your Mac, and every cleanup goes to the Trash first so you can undo it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            HStack(spacing: 24) {
                featureBullet("trash", "Cleanup")
                featureBullet("circle.hexagongrid", "Space Lens")
                featureBullet("shield", "Protection")
                featureBullet("gauge.with.dots.needle.67percent", "Performance")
            }
            .padding(.top, 8)
        }
    }

    private func featureBullet(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
            Text(title)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(width: 90)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Permissions")
                .font(.title.weight(.bold))
            Text("The app only asks for what each feature needs. Status updates live as you change settings; use Refresh if it lags.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, state: appState.permissions[kind]) {
                        await grant(kind)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(isRefreshing)
            }
        }
    }

    private var helperStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Privileged Helper")
                .font(.title.weight(.bold))
            Text("Some tasks need administrator rights: clearing system caches, flushing DNS, running maintenance scripts. They go through a small helper that only accepts a fixed list of operations and never runs arbitrary commands.")
                .foregroundStyle(.secondary)

            GlassCard {
                HStack(spacing: 14) {
                    Image(systemName: helper.isInstalled ? "checkmark.seal.fill" : "lock.shield")
                        .font(.title)
                        .foregroundStyle(helper.isInstalled ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Helper status")
                            .font(.headline)
                        Text(helper.statusLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let error = helper.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    if helper.status == .requiresApproval {
                        Button("Open Login Items") { HelperInstaller.openLoginItemsSettings() }
                            .buttonStyle(.glass)
                    }
                    Button(helper.isInstalled ? "Installed" : "Install Helper") {
                        helper.install()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(helper.isInstalled)
                }
            }

            Text("You can install or remove the helper later in Settings › Advanced.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { candidate in
                    Circle()
                        .fill(candidate == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(Text("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)"))

            Spacer()

            if step != .welcome {
                Button("Back") {
                    if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
                }
                .buttonStyle(.glass)
            }
            if step == .helper {
                Button("Skip for Now") { onFinish() }
                    .buttonStyle(.glass)
                Button("Finish") { onFinish() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") {
                    if let next = Step(rawValue: step.rawValue + 1) { step = next }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: Actions

    private func refresh() async {
        isRefreshing = true
        await appState.refreshPermissions()
        helper.refresh()
        isRefreshing = false
    }

    private func grant(_ kind: PermissionKind) async {
        switch kind {
        case .fullDiskAccess:
            PermissionChecker.openSystemSettings(for: .fullDiskAccess)
        case .accessibility:
            PermissionChecker.promptAccessibility()
            PermissionChecker.openSystemSettings(for: .accessibility)
        case .notifications:
            if appState.permissions.notifications == .notDetermined {
                _ = await PermissionChecker.requestNotifications()
            } else {
                PermissionChecker.openSystemSettings(for: .notifications)
            }
        }
        await refresh()
    }
}

/// One permission with live status and an action button.
struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let action: @MainActor () async -> Void

    @State private var isWorking = false

    var body: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 14) {
                Image(systemName: kind.systemImage)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.headline)
                    Text(kind.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Label(state.label, systemImage: state.systemImage)
                    .font(.callout)
                    .foregroundStyle(statusColor)
                    .labelStyle(.titleAndIcon)
                Button(buttonTitle) {
                    isWorking = true
                    Task {
                        await action()
                        isWorking = false
                    }
                }
                .buttonStyle(.glass)
                .disabled(state.isGranted || isWorking)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var buttonTitle: String {
        if state.isGranted { return "Granted" }
        if kind == .notifications, state == .notDetermined { return "Allow" }
        return "Open System Settings"
    }

    private var statusColor: Color {
        switch state {
        case .granted: return .green
        case .denied: return .orange
        case .notDetermined, .unknown: return .secondary
        }
    }
}

#Preview {
    OnboardingView {}
        .environment(AppState())
}
