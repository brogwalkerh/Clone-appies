import SwiftUI

// MARK: - PrimaryActionButton

/// The one large glass pill at the bottom of every module ("Scan", "Clean 12.4 GB").
/// Uses the stock prominent glass style so the system transparency slider and
/// Reduce Transparency apply automatically.
public struct PrimaryActionButton: View {
    public let title: String
    public let bytes: Int64?
    public let isLoading: Bool
    public let isEnabled: Bool
    public let action: @MainActor () -> Void

    public init(_ title: String,
                bytes: Int64? = nil,
                isLoading: Bool = false,
                isEnabled: Bool = true,
                action: @escaping @MainActor () -> Void) {
        self.title = title
        self.bytes = bytes
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                if let bytes {
                    ByteText(bytes, size: 20)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .frame(minWidth: 200)
            .contentShape(Capsule())
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.extraLarge)
        .disabled(!isEnabled || isLoading)
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
    }

    private var accessibilityText: Text {
        if let bytes {
            return Text("\(title), \(ByteText.string(bytes))")
        }
        return Text(title)
    }
}

// MARK: - GlassCard

/// A panel. Uses `.regularMaterial` (PLAN.md §4: glass for floating controls,
/// materials for panels). Optional tint draws a thin colored edge.
public struct GlassCard<Content: View>: View {
    private let tint: Color?
    private let padding: CGFloat
    private let content: Content

    public init(tint: Color? = nil,
                padding: CGFloat = Metrics.cardPadding,
                @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
        content
            .padding(padding)
            .background(.regularMaterial, in: shape)
            .overlay {
                if let tint {
                    shape.strokeBorder(tint.opacity(0.35), lineWidth: 1)
                }
            }
    }
}

// MARK: - StatPill

/// Icon + value + caption in a small glass capsule. Used in Smart Care and the menu app.
public struct StatPill: View {
    public let systemImage: String
    public let value: String
    public let caption: String
    public let tint: Color?

    public init(systemImage: String, value: String, caption: String, tint: Color? = nil) {
        self.systemImage = systemImage
        self.value = value
        self.caption = caption
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint ?? Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.headline, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(caption): \(value)"))
    }
}

// MARK: - ToolbarBell

/// Notification Center bell for the toolbar, with an unread badge.
public struct ToolbarBell: View {
    public let unreadCount: Int
    public let action: @MainActor () -> Void

    public init(unreadCount: Int, action: @escaping @MainActor () -> Void) {
        self.unreadCount = unreadCount
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: unreadCount > 0 ? "bell.badge" : "bell")
                .symbolRenderingMode(unreadCount > 0 ? .multicolor : .monochrome)
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(.red))
                            .offset(x: 8, y: -8)
                    }
                }
        }
        .help(unreadCount > 0 ? "\(unreadCount) unread notifications" : "Notifications")
        .accessibilityLabel(unreadCount > 0
                            ? Text("Notifications, \(unreadCount) unread")
                            : Text("Notifications"))
    }
}

// MARK: - Previews

#Preview("Primary action") {
    GlassEffectContainer {
        VStack(spacing: 16) {
            PrimaryActionButton("Scan") {}
            PrimaryActionButton("Clean", bytes: 12_400_000_000) {}
            PrimaryActionButton("Scanning…", isLoading: true) {}
            PrimaryActionButton("Clean", bytes: 0, isEnabled: false) {}
        }
        .padding(32)
    }
}

#Preview("Card, pill, bell") {
    VStack(spacing: 20) {
        GlassCard(tint: ModuleTint.cleanup.fallbackColor) {
            VStack(alignment: .leading) {
                Text("Cleanup").font(.headline)
                Text("12.4 GB of junk found").foregroundStyle(.secondary)
            }
        }
        HStack {
            StatPill(systemImage: "internaldrive", value: "128 GB", caption: "Free space")
            StatPill(systemImage: "memorychip", value: "6.2 GB", caption: "RAM used",
                     tint: ModuleTint.performance.fallbackColor)
        }
        HStack {
            ToolbarBell(unreadCount: 0) {}
            ToolbarBell(unreadCount: 3) {}
            ToolbarBell(unreadCount: 120) {}
        }
    }
    .padding(32)
    .frame(width: 420)
}
