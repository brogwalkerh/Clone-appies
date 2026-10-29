import Charts
import SwiftUI
import CleanerCore
import DesignSystem
import SmartCareModule

/// My Activity dashboard (PLAN.md §3.12): space reclaimed over time, threats
/// quarantined and an estimate of time saved, from the activity log the app
/// and the CLI share (ADR 0007).
struct MyActivityView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var confirmClear = false

    private var activity: ActivityCenter { ActivityCenter.shared }

    private struct Bar: Identifiable {
        let id: String
        let week: Date
        let gigabytes: Double
        let module: String
    }

    /// Modules that free space, in legend order.
    private let charted: [ModuleID] = [.cleanup, .applications, .clutter, .performance]

    private var bars: [Bar] {
        activity.stats.weeks.flatMap { week in
            charted.map { module in
                Bar(id: "\(week.start.timeIntervalSince1970)-\(module.rawValue)",
                    week: week.start,
                    gigabytes: Double(week.bytesByModule[module] ?? 0) / 1_000_000_000,
                    module: module.displayName)
            }
        }
    }

    var body: some View {
        let stats = activity.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    StatPill(systemImage: "internaldrive",
                             value: ByteFormatter.string(stats.bytesReclaimed),
                             caption: "Reclaimed in total",
                             tint: ModuleTint.cleanup.color(for: scheme, contrast: contrast))
                    StatPill(systemImage: "calendar",
                             value: ByteFormatter.string(stats.bytesReclaimedLast30Days),
                             caption: "Last 30 days",
                             tint: ModuleTint.clutter.color(for: scheme, contrast: contrast))
                    StatPill(systemImage: "shield.checkered",
                             value: "\(stats.threatsQuarantined)",
                             caption: "Threats quarantined",
                             tint: ModuleTint.protection.color(for: scheme, contrast: contrast))
                    StatPill(systemImage: "clock",
                             value: Self.duration(stats.estimatedTimeSaved),
                             caption: "Time saved (estimate)",
                             tint: ModuleTint.performance.color(for: scheme, contrast: contrast))
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Storage reclaimed per week")
                            .font(.headline)
                        if stats.weeks.allSatisfy({ $0.totalBytes == 0 }) {
                            Text("Nothing reclaimed in the last \(stats.weeks.count) weeks. Run Smart Care to start.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            Chart(bars) { bar in
                                BarMark(
                                    x: .value("Week", bar.week, unit: .weekOfYear),
                                    y: .value("GB", bar.gigabytes)
                                )
                                .foregroundStyle(by: .value("Module", bar.module))
                            }
                            .chartForegroundStyleScale([
                                ModuleID.cleanup.displayName: ModuleTint.cleanup.color(for: scheme, contrast: contrast),
                                ModuleID.applications.displayName: ModuleTint.applications.color(for: scheme, contrast: contrast),
                                ModuleID.clutter.displayName: ModuleTint.clutter.color(for: scheme, contrast: contrast),
                                ModuleID.performance.displayName: ModuleTint.performance.color(for: scheme, contrast: contrast),
                            ])
                            .chartYAxisLabel("GB")
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                                    AxisGridLine()
                                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                }
                            }
                            .frame(height: 260)
                            .accessibilityLabel("Bar chart of gigabytes reclaimed per week by module")
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent activity")
                            .font(.headline)
                        if activity.recent.isEmpty {
                            Text("Scans, cleanups, quarantines and maintenance runs appear here.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(activity.recent.prefix(20)) { event in
                                HStack(spacing: 10) {
                                    Image(systemName: Self.symbol(for: event.kind))
                                        .frame(width: 20)
                                        .foregroundStyle(.secondary)
                                    Text(event.title)
                                    Spacer()
                                    if event.bytes > 0, event.kind != .scan {
                                        Text(ByteFormatter.string(event.bytes))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(event.date, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 110, alignment: .trailing)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("My Activity")
        .toolbar {
            ToolbarItem {
                Button("Clear History") { confirmClear = true }
                    .disabled(activity.recent.isEmpty)
            }
        }
        .confirmationDialog("Clear all activity history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                Task { await activity.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Totals and the chart start again from zero. Files and undo manifests are not affected.")
        }
        .task {
            await activity.reload()
        }
    }

    static func symbol(for kind: ActivityKind) -> String {
        switch kind {
        case .scan: return "magnifyingglass"
        case .removal: return "trash"
        case .undo: return "arrow.uturn.backward"
        case .quarantine: return "shield.lefthalf.filled"
        case .maintenance: return "gauge.with.dots.needle.67percent"
        case .actionSet: return "square.stack.3d.up"
        }
    }

    /// "about 2 h 10 min", "45 min", "under a minute".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        let hours = minutes / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
    }
}

#Preview {
    MyActivityView()
        .environment(AppState())
        .frame(width: 1000, height: 760)
}
