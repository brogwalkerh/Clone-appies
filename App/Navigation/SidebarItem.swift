import SwiftUI
import CleanerCore
import DesignSystem

/// Every destination reachable from the sidebar. Order of `allCases` is the
/// sidebar order from PLAN.md §4 (Smart Care, pins, modules, clutter, cloud,
/// email, Space Lens, activity, menu).
enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case smartCare
    case cleanup
    case protection
    case performance
    case applications
    case myClutter
    case cloudCleanup
    case emailCleanup
    case spaceLens
    case myActivity
    case menuApp

    var id: String { rawValue }

    /// Sidebar grouping. "My Tools" pins are user-chosen items shown in their own
    /// section above the modules; see `AppState.pinnedTools`.
    enum Section: Hashable, CaseIterable {
        case home, pinnedTools, modules, more

        var title: String? {
            switch self {
            case .home: return nil
            case .pinnedTools: return "My Tools"
            case .modules: return "Modules"
            case .more: return "More"
            }
        }
    }

    var section: Section {
        switch self {
        case .smartCare:
            return .home
        case .cleanup, .protection, .performance, .applications, .myClutter:
            return .modules
        case .cloudCleanup, .emailCleanup, .spaceLens, .myActivity, .menuApp:
            return .more
        }
    }

    static func items(in section: Section) -> [SidebarItem] {
        allCases.filter { $0.section == section }
    }

    var title: String {
        switch self {
        case .smartCare: return "Smart Care"
        case .cleanup: return "Cleanup"
        case .protection: return "Protection"
        case .performance: return "Performance"
        case .applications: return "Applications"
        case .myClutter: return "My Clutter"
        case .cloudCleanup: return "Cloud Cleanup"
        case .emailCleanup: return "Email Cleanup"
        case .spaceLens: return "Space Lens"
        case .myActivity: return "My Activity"
        case .menuApp: return "Menu"
        }
    }

    var systemImage: String {
        switch self {
        case .smartCare: return "sparkles"
        case .cleanup: return "trash"
        case .protection: return "shield"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .applications: return "square.grid.2x2"
        case .myClutter: return "doc.on.doc"
        case .cloudCleanup: return "icloud"
        case .emailCleanup: return "envelope"
        case .spaceLens: return "circle.hexagongrid"
        case .myActivity: return "chart.bar"
        case .menuApp: return "menubar.rectangle"
        }
    }

    var tint: ModuleTint {
        switch self {
        case .cleanup: return .cleanup
        case .protection: return .protection
        case .performance: return .performance
        case .applications: return .applications
        case .myClutter: return .clutter
        case .smartCare, .cloudCleanup, .emailCleanup, .spaceLens, .myActivity, .menuApp:
            return .accent
        }
    }

    /// The `CleanerCore` module this destination hosts, if it is one of the five.
    var moduleID: ModuleID? {
        switch self {
        case .cleanup: return .cleanup
        case .protection: return .protection
        case .performance: return .performance
        case .applications: return .applications
        case .myClutter: return .clutter
        default: return nil
        }
    }

    /// ⌘1–⌘9. `nil` for items without a shortcut.
    var shortcutDigit: Character? {
        switch self {
        case .smartCare: return "1"
        case .cleanup: return "2"
        case .protection: return "3"
        case .performance: return "4"
        case .applications: return "5"
        case .myClutter: return "6"
        case .cloudCleanup: return "7"
        case .emailCleanup: return "8"
        case .spaceLens: return "9"
        case .myActivity, .menuApp: return nil
        }
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let digit = shortcutDigit else { return nil }
        return KeyboardShortcut(KeyEquivalent(digit), modifiers: .command)
    }

    /// Milestone in which the module ships (PLAN.md §7); `nil` once implemented.
    var pendingMilestone: String? {
        switch self {
        case .cleanup, .spaceLens, .applications, .myClutter, .performance, .menuApp, .protection: return nil
        case .smartCare, .myActivity: return "M5"
        case .cloudCleanup, .emailCleanup: return "M6"
        }
    }

    /// Items that can be pinned into "My Tools".
    var isPinnable: Bool { self != .smartCare }
}
