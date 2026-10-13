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
            MenuBarLabel(pressure: state.stats?.memoryPressure)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status-item label: the sparkles symbol plus a small dot that turns
/// amber or red under memory pressure. Under normal pressure the dot is
/// omitted so the item looks like any other monochrome status icon.
struct MenuBarLabel: View {
    let pressure: MemoryPressure?

    var body: some View {
        // TODO(macOS27): MenuBarExtra renders the label as a template image, so the
        // dot may come out monochrome. If so, swap to "sparkles" / "exclamationmark.triangle"
        // symbols per pressure level instead of a colored circle.
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
            if let pressure, pressure != .normal {
                Circle()
                    .fill(MenuBarLabel.dotColor(for: pressure))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        switch pressure {
        case .warn: return "Mac Cleaner, memory pressure elevated"
        case .critical: return "Mac Cleaner, memory pressure critical"
        default: return "Mac Cleaner"
        }
    }

    static func dotColor(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warn: return .yellow
        case .critical: return .red
        }
    }
}
