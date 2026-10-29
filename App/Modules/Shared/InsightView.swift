import SwiftUI
import CleanerCore
import SmartCareModule

/// "What is this?" popover for one finding (Smart Insights, PLAN.md §3.2).
struct InsightView: View {
    let finding: Finding

    @State private var insight: Insight?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(finding.path.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if isLoading {
                ProgressView("Looking this up…")
                    .controlSize(.small)
            } else if let insight {
                Text(insight.explanation)
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.advice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(insight.source == .onDeviceModel ? "Explained on this Mac by Apple Intelligence" : "From the built-in cleanup rules",
                      systemImage: insight.source == .onDeviceModel ? "sparkles" : "book")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("No explanation is available for this item.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .task {
            insight = await InsightService.provider.insight(for: finding,
                                                            home: FileManager.default.homeDirectoryForCurrentUser)
            isLoading = false
        }
    }
}
