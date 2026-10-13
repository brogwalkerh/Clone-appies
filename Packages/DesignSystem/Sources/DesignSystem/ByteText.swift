import Foundation
import SwiftUI

/// Renders a byte count as a large rounded numeral with a smaller unit,
/// e.g. **12.4** GB. Mirrors `CleanerCore.ByteFormatter` (decimal units, one
/// decimal place) but lives here so DesignSystem stays dependency-free.
public struct ByteText: View {
    public let bytes: Int64
    public let size: CGFloat
    public let weight: Font.Weight

    public init(_ bytes: Int64, size: CGFloat = 34, weight: Font.Weight = .semibold) {
        self.bytes = bytes
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        let parts = ByteText.components(bytes)
        HStack(alignment: .firstTextBaseline, spacing: size * 0.12) {
            Text(parts.value)
                .font(.system(size: size, weight: weight, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(parts.unit)
                .font(.system(size: size * 0.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(parts.value) \(parts.unit)"))
    }

    /// Splits a byte count into a numeral and a unit using decimal (1000-based) units.
    public static func components(_ bytes: Int64) -> (value: String, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(max(bytes, 0))
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 {
            return (String(Int64(value)), units[index])
        }
        return (String(format: "%.1f", locale: Locale.current, value), units[index])
    }

    /// Single-string form, e.g. "12.4 GB".
    public static func string(_ bytes: Int64) -> String {
        let parts = components(bytes)
        return "\(parts.value) \(parts.unit)"
    }
}

#Preview("ByteText") {
    VStack(alignment: .leading, spacing: 16) {
        ByteText(0)
        ByteText(532)
        ByteText(12_400_000_000, size: 56)
        ByteText(1_234_567_890_123, size: 20, weight: .medium)
    }
    .padding(24)
}
