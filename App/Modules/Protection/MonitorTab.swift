import Foundation
import SwiftUI
import Observation
import DesignSystem

/// Reads the status keys the menu bar agent writes to the shared suite
/// (`MenuAgentSettings.Key.monitorLastEvent` / `.monitorThreatCount`). The agent
/// owns the FSEvents `ProtectionMonitor`; the main app only observes.
@MainActor
@Observable
final class MonitorStatusReader {
    private(set) var lastEvent: Date?
    private(set) var threatCount = 0
    private(set) var lastReadAt: Date?

    func refresh() {
        let store = MenuAgentSettings.store
        lastEvent = store.object(forKey: MenuAgentSettings.Key.monitorLastEvent) as? Date
        threatCount = store.integer(forKey: MenuAgentSettings.Key.monitorThreatCount)
        lastReadAt = .now
    }

    /// Re-reads the suite until the task is cancelled (the Monitor tab's `.task(id:)`).
    func poll(every interval: Duration) async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: interval)
        }
    }

    enum Health: Hashable {
        case agentOff
        case monitorOff
        case waiting
        case running
        case threats(Int)

        var color: Color {
            switch self {
            case .agentOff, .monitorOff: return .secondary
            case .waiting: return .orange
            case .running: return .green
            case .threats: return .red
            }
        }

        var systemImage: String {
            switch self {
            case .agentOff, .monitorOff: return "shield.slash"
            case .waiting: return "shield"
            case .running: return "checkmark.shield.fill"
            case .threats: return "exclamationmark.shield.fill"
            }
        }
    }

    func health(monitorEnabled: Bool, agentEnabled: Bool) -> Health {
        if !agentEnabled { return .agentOff }
        if !monitorEnabled { return .monitorOff }
        if threatCount > 0 { return .threats(threatCount) }
        return lastEvent == nil ? .waiting : .running
    }

    func statusLine(monitorEnabled: Bool, agentEnabled: Bool) -> String {
        switch health(monitorEnabled: monitorEnabled, agentEnabled: agentEnabled) {
        case .agentOff:
            return "Menu bar agent is off"
        case .monitorOff:
            return "Monitor is off"
        case .waiting:
            return "Waiting for the agent to start the monitor"
        case .running:
            if let lastEvent {
                return "Running • last activity \(lastEvent.formatted(.relative(presentation: .named)))"
            }
            return "Running"
        case .threats(let count):
            let when = lastEvent.map { " • last \($0.formatted(.relative(presentation: .named)))" } ?? ""
            return "\(count) \(count == 1 ? "threat" : "threats") found\(when)"
        }
    }
}

/// Protection › Monitor: explains and configures the FSEvents-based Protection
/// Monitor that runs inside the menu bar agent (CONTRACTS.md "M4 — UIKitBridge
/// additions"). Three `GlassCard`s in a 760 pt column like the Menu screen.
struct MonitorTab: View {
    @Binding var isEnabled: Bool
    let agentEnabled: Bool
    let status: MonitorStatusReader
    let onOpenMenu: @MainActor () -> Void

    /// Default watch list from the `ProtectionMonitor` initializer.
    static let watchedPaths: [String] = [
        "~/Downloads",
        "/Applications",
        "~/Library/LaunchAgents",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons"
    ]

    private var health: MonitorStatusReader.Health {
        status.health(monitorEnabled: isEnabled, agentEnabled: agentEnabled)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusCard
                settingsCard
                if !agentEnabled {
                    agentHintCard
                }
            }
            .padding(32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Cards

    private var statusCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: health.systemImage)
                    .font(.title)
                    .foregroundStyle(health.color)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Protection Monitor")
                        .font(.headline)
                    Text(status.statusLine(monitorEnabled: isEnabled, agentEnabled: agentEnabled))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Text("Watches the folders below for new and changed files, checks them against the signature database and heuristics, and notes the quarantine flag on fresh downloads. It runs in the menu bar agent so it keeps working after this window closes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if case .threats(let count) = health {
                    Text("\(count)")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("\(count) threats"))
                }
            }
        }
    }

    private var settingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Watch for threats in real time")
                            .font(.headline)
                        Text("Uses FSEvents, so it costs nothing while nothing changes. An Endpoint Security version arrives once Apple approves the entitlement.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Text("Watched locations")
                    .font(.subheadline.weight(.semibold))
                ForEach(MonitorTab.watchedPaths, id: \.self) { path in
                    Label {
                        Text(path)
                            .font(.callout)
                    } icon: {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Threats the monitor finds show up in the menu bar with a red dot; click the row to open this module.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentHintCard: some View {
        GlassCard(tint: .orange) {
            HStack(spacing: 14) {
                Image(systemName: "menubar.rectangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Requires the menu bar agent to be enabled")
                        .font(.headline)
                    Text("The monitor is part of the login-item agent. Enable it from the Menu screen; your choice here is kept and applies as soon as the agent runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open Menu") { onOpenMenu() }
                    .buttonStyle(.glass)
            }
        }
    }
}

#Preview {
    MonitorTab(isEnabled: .constant(true),
               agentEnabled: false,
               status: MonitorStatusReader(),
               onOpenMenu: {})
        .frame(width: 1000, height: 700)
}
