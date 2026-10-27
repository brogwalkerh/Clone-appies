import SwiftUI

/// A plain sRGB triple. Kept as numbers (not `Color`) so high-contrast variants
/// can be derived arithmetically; asset catalogs cannot be authored in this repo.
public struct RGB: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Moves the color toward black (negative) or white (positive) by `amount` in 0...1.
    func shifted(by amount: Double) -> RGB {
        func mix(_ channel: Double) -> Double {
            let target = amount < 0 ? 0.0 : 1.0
            return min(1, max(0, channel + (target - channel) * abs(amount)))
        }
        return RGB(mix(red), mix(green), mix(blue))
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

/// A color with a light and a dark variant, resolved against the current
/// `ColorScheme` and `ColorSchemeContrast`. Stand-in for an asset-catalog color.
public struct ThemedColor: Sendable, Hashable {
    public let light: RGB
    public let dark: RGB

    public init(light: RGB, dark: RGB) {
        self.light = light
        self.dark = dark
    }

    /// Resolves the color. Increased contrast deepens light-mode colors and
    /// brightens dark-mode colors so text and strokes stay legible over glass.
    public func resolved(for scheme: ColorScheme,
                         contrast: ColorSchemeContrast = .standard) -> Color {
        let base = scheme == .dark ? dark : light
        switch contrast {
        case .increased:
            return base.shifted(by: scheme == .dark ? 0.18 : -0.18).color
        default:
            return base.color
        }
    }
}

/// The five module tints plus the single brand accent (PLAN.md §4).
public enum ModuleTint: String, CaseIterable, Sendable, Hashable, Identifiable {
    case cleanup
    case protection
    case performance
    case applications
    case clutter
    case accent

    public var id: String { rawValue }

    public var themed: ThemedColor {
        switch self {
        case .cleanup:
            return ThemedColor(light: RGB(0.18, 0.66, 0.36), dark: RGB(0.32, 0.80, 0.47))
        case .protection:
            return ThemedColor(light: RGB(0.00, 0.47, 0.98), dark: RGB(0.14, 0.60, 1.00))
        case .performance:
            return ThemedColor(light: RGB(0.98, 0.54, 0.10), dark: RGB(1.00, 0.63, 0.22))
        case .applications:
            return ThemedColor(light: RGB(0.54, 0.30, 0.90), dark: RGB(0.69, 0.48, 1.00))
        case .clutter:
            return ThemedColor(light: RGB(0.00, 0.60, 0.65), dark: RGB(0.26, 0.78, 0.80))
        case .accent:
            return ThemedColor(light: RGB(0.33, 0.39, 0.97), dark: RGB(0.50, 0.56, 1.00))
        }
    }

    public func color(for scheme: ColorScheme,
                      contrast: ColorSchemeContrast = .standard) -> Color {
        themed.resolved(for: scheme, contrast: contrast)
    }

    /// Convenience when the caller cannot read the environment (previews, Canvas).
    public var fallbackColor: Color { themed.light.color }
}

/// Resolves a `ModuleTint` against the environment and applies it as the view's tint.
private struct ModuleTintModifier: ViewModifier {
    let tint: ModuleTint
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.tint(tint.color(for: scheme, contrast: contrast))
    }
}

/// Applies a resolved module tint as `foregroundStyle`.
private struct ModuleForegroundModifier: ViewModifier {
    let tint: ModuleTint
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(tint.color(for: scheme, contrast: contrast))
    }
}

public extension View {
    /// Tints controls (buttons, toggles, progress) with a module color.
    func moduleTint(_ tint: ModuleTint) -> some View {
        modifier(ModuleTintModifier(tint: tint))
    }

    /// Colors text and symbols with a module color.
    func moduleForeground(_ tint: ModuleTint) -> some View {
        modifier(ModuleForegroundModifier(tint: tint))
    }
}

/// Reads the environment and hands the caller a resolved `Color`.
/// Useful for `Canvas` drawing and shape fills that need a concrete `Color`.
public struct ResolvedTint<Content: View>: View {
    let tint: ModuleTint
    let content: (Color) -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ tint: ModuleTint, @ViewBuilder content: @escaping (Color) -> Content) {
        self.tint = tint
        self.content = content
    }

    public var body: some View {
        content(tint.color(for: scheme, contrast: contrast))
    }
}

/// Shared spacing and radius constants so modules line up.
public enum Metrics {
    public static let cardCornerRadius: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let bottomBarHeight: CGFloat = 84
    public static let minimumWindowSize = CGSize(width: 1200, height: 800)
}

#Preview("Module tints") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(ModuleTint.allCases) { tint in
            HStack {
                Circle()
                    .frame(width: 20, height: 20)
                    .moduleForeground(tint)
                Text(tint.rawValue.capitalized)
                    .moduleForeground(tint)
                Spacer()
                Button("Action") {}
                    .buttonStyle(.glassProminent)
                    .moduleTint(tint)
            }
        }
    }
    .padding(24)
    .frame(width: 320)
}
