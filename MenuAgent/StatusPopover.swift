import DesignSystem
import SwiftUI
import UIKitBridge

/// The ~320 pt popover behind the status item (docs/design/UI-SPEC.md §6).
struct StatusPopover: View {
    let state: AgentState

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private let width: CGFloat = 320

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 12) {
                header
                statsSection
                utilitySection
                actionButtons
            }
            .padding(14)
        }
        .frame(width: width)
        .background(.regularMaterial)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(headerBadgeFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Cleaner")
                    .font(.headline)
                Text(state.stats == nil ? "Measuring…" : "Menu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(state.stats == nil ? .updatesFrequently : [])
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    /// Accent → performance tint gradient; a flat accent fill under Reduce Transparency.
    private var headerBadgeFill: AnyShapeStyle {
        let accent = ModuleTint.accent.color(for: scheme, contrast: contrast)
        if reduceTransparency {
            return AnyShapeStyle(accent)
        }
        let performance = ModuleTint.performance.color(for: scheme, contrast: contrast)
        return AnyShapeStyle(LinearGradient(colors: [accent, performance],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing))
    }

    // MARK: Stats rows

    @ViewBuilder
    private var statsSection: some View {
        let stats = state.stats
        VStack(spacing: 8) {
            row {
                StatPill(systemImage: "cpu",
                         value: stats.map { String(format: "%.0f %%", $0.cpuPercent) } ?? "– %",
                         caption: "CPU",
                         tint: ModuleTint.performance.color(for: scheme, contrast: contrast))
            }

            row {
                StatPill(systemImage: "memorychip",
                         value: stats.map { "\(ByteText.string($0.memoryUsedBytes)) / \(ByteText.string($0.memoryTotalBytes))" } ?? "–",
                         caption: "Memory",
                         tint: ModuleTint.performance.color(for: scheme, contrast: contrast))
            } trailing: {
                if let pressure = stats?.memoryPressure {
                    PressureBadge(pressure: pressure)
                }
                Button("Free Up") { state.freeUpRAM() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Free up RAM in Mac Cleaner")
            }

            row {
                StatPill(systemImage: "internaldrive",
                         value: stats.map { "\(ByteText.string($0.diskUsedBytes)) / \(ByteText.string($0.diskTotalBytes))" } ?? "–",
                         caption: stats.map { "\(ByteText.string($0.purgeableBytes)) purgeable" } ?? "Disk",
                         tint: ModuleTint.cleanup.color(for: scheme, contrast: contrast))
            }

            if let stats, let percent = stats.batteryPercent {
                row {
                    StatPill(systemImage: stats.isCharging == true ? "battery.100percent.bolt" : "battery.75percent",
                             value: String(format: "%.0f %%", percent),
                             caption: StatusPopover.batteryCaption(stats),
                             tint: ModuleTint.cleanup.color(for: scheme, contrast: contrast))
                }
            }

            row {
                StatPill(systemImage: "arrow.up.arrow.down",
                         value: stats.map { "↓ \(StatusPopover.rate($0.networkInBytesPerSec))  ↑ \(StatusPopover.rate($0.networkOutBytesPerSec))" } ?? "↓ –  ↑ –",
                         caption: "Network",
                         tint: ModuleTint.protection.color(for: scheme, contrast: contrast))
            }
        }
    }

    // MARK: Trash + Protection

    private var utilitySection: some View {
        VStack(spacing: 8) {
            row {
                StatPill(systemImage: "trash",
                         value: state.trashBytes.map(ByteText.string) ?? "–",
                         caption: "Trash",
                         tint: ModuleTint.cleanup.color(for: scheme, contrast: contrast))
            } trailing: {
                Button("Empty") { state.emptyTrash() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled((state.trashBytes ?? 0) == 0)
                    .help("Empty the Trash in Mac Cleaner")
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(.gray)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Protection Monitor")
                    .font(.subheadline)
                Spacer()
                Text("Available in M4")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Buttons

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button {
                state.runSmartCare()
            } label: {
                Label("Run Smart Care", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Button {
                state.startScreenCleaning()
            } label: {
                Label("Screen Cleaning Mode", systemImage: "display")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(state.isScreenCleaningActive)

            HStack(spacing: 8) {
                Button("Open Mac Cleaner") { state.openMainApp() }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                Button("Quit") { state.quit() }
                    .buttonStyle(.glass)
                    .keyboardShortcut("q")
            }
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

    private func row<Leading: View>(@ViewBuilder leading: () -> Leading) -> some View {
        row(leading: leading) { EmptyView() }
    }

    private func row<Leading: View, Trailing: View>(@ViewBuilder leading: () -> Leading,
                                                    @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 4)
            trailing()
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(ByteText.string(Int64(max(0, bytesPerSecond.rounded()))))/s"
    }

    static func batteryCaption(_ stats: SystemStats) -> String {
        var parts: [String] = [stats.isCharging == true ? "Charging" : "On battery"]
        if let cycles = stats.batteryCycleCount { parts.append("\(cycles) cycles") }
        if let health = stats.batteryHealth { parts.append(String(format: "%.0f %% health", health * 100)) }
        return parts.joined(separator: " • ")
    }
}

/// Small capsule reading Normal / Warn / Critical next to the memory pill.
struct PressureBadge: View {
    let pressure: MemoryPressure

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel(Text("Memory pressure \(label)"))
    }

    private var label: String {
        switch pressure {
        case .normal: return "Normal"
        case .warn: return "Warn"
        case .critical: return "Critical"
        }
    }

    private var color: Color {
        MenuBarLabel.dotColor(for: pressure)
    }
}

#Preview("Status popover") {
    StatusPopover(state: AgentState())
}
