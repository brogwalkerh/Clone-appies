import SwiftUI

/// Thin wrappers over `ContentUnavailableView` so every module uses the same
/// empty / needs-permission / scanning / coming-soon layouts.
public struct EmptyState: View {
    public enum Style: Sendable, Hashable {
        case symbol(String)
        case progress
    }

    public let title: String
    public let message: String?
    public let style: Style
    public let actionTitle: String?
    public let action: (@MainActor () -> Void)?

    public init(title: String,
                message: String? = nil,
                style: Style,
                actionTitle: String? = nil,
                action: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.message = message
        self.style = style
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            switch style {
            case .symbol(let name):
                Label(title, systemImage: name)
            case .progress:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(title)
                }
            }
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
            }
        }
    }

    // MARK: Factories

    /// A scan finished and found nothing.
    public static func nothingFound(_ what: String = "Nothing to clean",
                                    message: String? = "Your Mac is already tidy. Check back after a few days of use.",
                                    actionTitle: String? = nil,
                                    action: (@MainActor () -> Void)? = nil) -> EmptyState {
        EmptyState(title: what, message: message,
                   style: .symbol("checkmark.seal"),
                   actionTitle: actionTitle, action: action)
    }

    /// A permission (Full Disk Access, Accessibility, …) blocks this module.
    public static func needsPermission(_ permission: String,
                                       message: String? = nil,
                                       action: @escaping @MainActor () -> Void) -> EmptyState {
        EmptyState(title: "\(permission) Required",
                   message: message ?? "Grant \(permission) in System Settings so the app can see these files.",
                   style: .symbol("lock.shield"),
                   actionTitle: "Open System Settings",
                   action: action)
    }

    /// A scan is running and has not produced its first result yet.
    public static func scanning(_ what: String = "Scanning…",
                                message: String? = nil,
                                cancel: (@MainActor () -> Void)? = nil) -> EmptyState {
        EmptyState(title: what, message: message, style: .progress,
                   actionTitle: cancel == nil ? nil : "Cancel", action: cancel)
    }

    /// Placeholder for a module scheduled for a later milestone (PLAN.md §7).
    public static func comingSoon(feature: String,
                                  milestone: String,
                                  systemImage: String = "hammer",
                                  message: String? = nil) -> EmptyState {
        EmptyState(title: feature,
                   message: message ?? "Coming in \(milestone).",
                   style: .symbol(systemImage))
    }
}

#Preview("Empty states") {
    HStack(spacing: 0) {
        EmptyState.nothingFound()
        EmptyState.needsPermission("Full Disk Access") {}
        EmptyState.scanning("Scanning caches…", cancel: {})
        EmptyState.comingSoon(feature: "Protection", milestone: "M4", systemImage: "shield")
    }
    .frame(width: 1200, height: 360)
}
