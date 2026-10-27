import Charts
import SwiftUI
import CleanerCore
import DesignSystem

/// My Activity dashboard (PLAN.md §3.12). Charts render sample data until the
/// persistence layer lands in M5.
struct MyActivityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private struct ReclaimSample: Identifiable {
        let id = UUID()
        let week: Date
        let gigabytes: Double
        let module: String
    }

    private var samples: [ReclaimSample] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let values: [(Double, Double, Double)] = [
            (4.2, 1.1, 0.6), (2.8, 0.0, 1.9), (6.1, 2.4, 0.3), (1.5, 0.7, 0.0),
            (7.9, 1.8, 2.2), (3.3, 0.0, 0.9), (5.4, 3.1, 1.0), (2.2, 0.4, 0.5)
        ]
        return values.enumerated().flatMap { offset, triple -> [ReclaimSample] in
            let week = calendar.date(byAdding: .weekOfYear, value: offset - (values.count - 1), to: today) ?? today
            return [
                ReclaimSample(week: week, gigabytes: triple.0, module: "Cleanup"),
                ReclaimSample(week: week, gigabytes: triple.1, module: "Applications"),
                ReclaimSample(week: week, gigabytes: triple.2, module: "My Clutter")
            ]
        }
    }

    private var totalSampleGB: Double {
        samples.reduce(0) { $0 + $1.gigabytes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    StatPill(systemImage: "internaldrive",
                             value: String(format: "%.1f GB", totalSampleGB),
                             caption: "Reclaimed (sample)",
                             tint: ModuleTint.cleanup.color(for: scheme, contrast: contrast))
                    StatPill(systemImage: "shield.checkered",
                             value: "0",
                             caption: "Threats blocked",
                             tint: ModuleTint.protection.color(for: scheme, contrast: contrast))
                    StatPill(systemImage: "clock",
                             value: "~2 h",
                             caption: "Time saved (estimate)",
                             tint: ModuleTint.performance.color(for: scheme, contrast: contrast))
                    if let manifest = appState.lastCleanupManifest {
                        StatPill(systemImage: "trash",
                                 value: ByteFormatter.string(manifest.bytesReclaimed),
                                 caption: "Last cleanup")
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Storage reclaimed per week")
                            .font(.headline)
                        Chart(samples) { sample in
                            BarMark(
                                x: .value("Week", sample.week, unit: .weekOfYear),
                                y: .value("GB", sample.gigabytes)
                            )
                            .foregroundStyle(by: .value("Module", sample.module))
                        }
                        .chartForegroundStyleScale([
                            "Cleanup": ModuleTint.cleanup.color(for: scheme, contrast: contrast),
                            "Applications": ModuleTint.applications.color(for: scheme, contrast: contrast),
                            "My Clutter": ModuleTint.clutter.color(for: scheme, contrast: contrast)
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

                EmptyState.comingSoon(feature: "Live activity history",
                                      milestone: SidebarItem.myActivity.pendingMilestone ?? "M5",
                                      systemImage: "chart.bar",
                                      message: "Real scan history, cloud cleanup progress and threat stats arrive with persistence in M5. The chart above is sample data.")
                    .frame(height: 200)
            }
            .padding(32)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("My Activity")
    }
}

#Preview {
    MyActivityView()
        .environment(AppState())
        .frame(width: 1000, height: 760)
}
