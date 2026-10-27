import SwiftUI
import CleanerCore
import DesignSystem
import PerformanceModule

/// Performance › Maintenance: every `MaintenanceCatalog` task with a checkbox,
/// an expandable Smart Insights paragraph, a "Needs helper" badge, and — once a
/// run starts — a per-task status row (running / success / failed, bytes reclaimed).
struct MaintenanceTab: View {
    let maintenance: MaintenanceState
    let helperAvailable: Bool
    let onInstallHelper: @MainActor () -> Void

    @State private var expandedTaskIDs: Set<String> = []

    var body: some View {
        List {
            if maintenance.hasResults || maintenance.isRunning {
                Section("This run") {
                    ForEach(maintenance.runOrder, id: \.self) { taskID in
                        if let task = MaintenanceState.task(withID: taskID),
                           let status = maintenance.status(for: taskID) {
                            MaintenanceResultRow(task: task, status: status)
                        }
                    }
                }
            }

            Section("Tasks") {
                ForEach(MaintenanceCatalog.all) { task in
                    MaintenanceTaskRow(task: task,
                                       isSelected: selectionBinding(for: task),
                                       isExpanded: expansionBinding(for: task),
                                       needsHelper: task.requiresHelper && !helperAvailable,
                                       isLocked: maintenance.isRunning,
                                       onInstallHelper: onInstallHelper)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private func selectionBinding(for task: MaintenanceTask) -> Binding<Bool> {
        Binding(
            get: { maintenance.isSelected(task) },
            set: { maintenance.setSelected($0, for: task) })
    }

    private func expansionBinding(for task: MaintenanceTask) -> Binding<Bool> {
        Binding(
            get: { expandedTaskIDs.contains(task.id) },
            set: { expanded in
                if expanded { expandedTaskIDs.insert(task.id) } else { expandedTaskIDs.remove(task.id) }
            })
    }
}

// MARK: - Rows

struct MaintenanceTaskRow: View {
    let task: MaintenanceTask
    @Binding var isSelected: Bool
    @Binding var isExpanded: Bool
    let needsHelper: Bool
    let isLocked: Bool
    let onInstallHelper: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Toggle("", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(needsHelper || isLocked)
                    .accessibilityLabel(Text(task.name))

                Image(systemName: MaintenanceTaskRow.symbol(for: task.id))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(task.name)
                            .lineLimit(1)
                        if needsHelper {
                            PerformanceBadge(text: "Needs helper", color: .orange)
                        } else if task.requiresHelper {
                            PerformanceBadge(text: "Helper", color: .blue)
                        }
                        if task.risk != .safe {
                            RiskBadge(risk: task.risk)
                        }
                    }
                    Text(task.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if needsHelper {
                    Button("Install helper") { onInstallHelper() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }

                Text(MaintenanceTaskRow.estimate(task.estimatedSeconds))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isExpanded ? "Hide details for \(task.name)" : "Show details for \(task.name)"))
            }
            .opacity(needsHelper ? 0.6 : 1)

            if isExpanded {
                Text(task.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 52)
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { isExpanded.toggle() }
    }

    /// "~5 s", "~2 min".
    static func estimate(_ seconds: Int) -> String {
        if seconds < 60 { return "~\(max(seconds, 1)) s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        return "~\(minutes) min"
    }

    static func symbol(for taskID: String) -> String {
        let key = taskID.lowercased()
        if key.contains("ram") { return "memorychip" }
        if key.contains("purgeable") || key.contains("snapshot") { return "internaldrive" }
        if key.contains("periodic") { return "clock.arrow.circlepath" }
        if key.contains("dns") { return "network" }
        if key.contains("spotlight") { return "magnifyingglass" }
        if key.contains("launchservices") { return "app.badge" }
        if key.contains("mail") { return "envelope" }
        if key.contains("bluetooth") { return "wave.3.right" }
        if key.contains("font") { return "textformat" }
        if key.contains("permission") { return "lock.open" }
        return "wrench.and.screwdriver"
    }
}

struct MaintenanceResultRow: View {
    let task: MaintenanceTask
    let status: MaintenanceState.RowStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .lineLimit(1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer()

            if let bytes, bytes > 0 {
                Text(ByteFormatter.string(bytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let duration {
                Text(duration < 1 ? "<1 s" : "\(Int(duration.rounded())) s")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.orange)
        }
    }

    private var message: String {
        switch status {
        case .pending: return "Waiting…"
        case .running: return "Running…"
        case .succeeded(let result), .failed(let result): return result.message
        case .skipped(let reason): return reason
        }
    }

    private var bytes: Int64? {
        switch status {
        case .succeeded(let result), .failed(let result): return result.bytesReclaimed
        default: return nil
        }
    }

    private var duration: TimeInterval? {
        switch status {
        case .succeeded(let result), .failed(let result): return result.duration
        default: return nil
        }
    }
}
