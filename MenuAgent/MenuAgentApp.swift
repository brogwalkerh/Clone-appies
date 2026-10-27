import DesignSystem
import SwiftUI
import UIKitBridge

/// Menu bar login-item agent (PLAN.md §3.10). LSUIElement: no Dock icon, no
/// main menu, just a `MenuBarExtra` whose window-style popover is `StatusPopover`.
/// The main app registers this bundle with `SMAppService.loginItem`.
@main
struct MenuAgentApp: App {
    @State private var state = AgentState()

    var body: some Scene {
        MenuBarExtra {
            StatusPopover(state: state)
        } label: {
            MenuBarLabel(pressure: state.stats?.memoryPressure,
                         hasThreats: MenuBarLabel.hasThreats(state.monitorState))
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status-item label: the sparkles symbol plus a small dot that turns
/// amber or red under memory pressure, or red when the Protection Monitor has
/// found something (threats win over pressure). Under normal pressure with no
/// threats the dot is omitted so the item looks like any other monochrome
/// status icon.
struct MenuBarLabel: View {
    let pressure: MemoryPressure?
    var hasThreats: Bool = false

    var body: some View {
        // TODO(macOS27): MenuBarExtra renders the label as a template image, so the
        // dot may come out monochrome. If so, swap to "sparkles" / "exclamationmark.triangle"
        // symbols per pressure level instead of a colored circle.
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
            if let dot = dotColor {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel(Text(accessibilityText))
    }

    private var dotColor: Color? {
        if hasThreats { return .red }
        if let pressure, pressure != .normal { return MenuBarLabel.dotColor(for: pressure) }
        return nil
    }

    private var accessibilityText: String {
        if hasThreats { return "Mac Cleaner, threats found" }
        switch pressure {
        case .warn: return "Mac Cleaner, memory pressure elevated"
        case .critical: return "Mac Cleaner, memory pressure critical"
        default: return "Mac Cleaner"
        }
    }

    static func hasThreats(_ state: AgentState.MonitorState) -> Bool {
        if case .threats = state { return true }
        return false
    }

    static func dotColor(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warn: return .yellow
        case .critical: return .red
        }
    }
}
