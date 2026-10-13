import SwiftUI

/// Circular scan progress that morphs into the result numeral (PLAN.md §4, Motion).
///
/// - `.idle`: faint ring with a sparkle glyph.
/// - `.scanning(fraction:)`: ring fills to `fraction`; `nil` spins an indeterminate arc.
/// - `.result(...)`: ring completes and the center shows a large rounded numeral.
///
/// Honors Reduce Motion: no spinning arc and no spring on phase changes.
public struct ScanRing: View {
    public enum Phase: Hashable, Sendable {
        case idle
        case scanning(fraction: Double?)
        case result(value: String, unit: String?, caption: String?)
    }

    public let phase: Phase
    public let tint: Color
    public let diameter: CGFloat
    public let lineWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinAngle: Double = 0

    public init(phase: Phase,
                tint: Color = .accentColor,
                diameter: CGFloat = 220,
                lineWidth: CGFloat = 14) {
        self.phase = phase
        self.tint = tint
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: trimEnd)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90 + spinAngle))

            center
                .padding(lineWidth * 2)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .spring(duration: 0.6), value: phase)
        .onChange(of: isIndeterminate, initial: true) { _, spinning in
            updateSpin(spinning)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isScanning ? .updatesFrequently : [])
    }

    // MARK: Pieces

    @ViewBuilder
    private var center: some View {
        switch phase {
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: diameter * 0.22, weight: .medium))
                .foregroundStyle(tint)
                .transition(.opacity)

        case .scanning(let fraction):
            VStack(spacing: 4) {
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } else if reduceMotion {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Text("Scanning")
                        .font(.system(.title2, design: .rounded).weight(.medium))
                }
                Text("Scanning…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .opacity(fraction == nil ? 0 : 1)
            }
            .transition(.opacity)

        case .result(let value, let unit, let caption):
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit)
                            .font(.system(size: 24, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private var trimEnd: CGFloat {
        switch phase {
        case .idle:
            return 0
        case .scanning(let fraction):
            if let fraction {
                return CGFloat(min(max(fraction, 0.02), 1))
            }
            return reduceMotion ? 0.0 : 0.28
        case .result:
            return 1
        }
    }

    private var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    private var isIndeterminate: Bool {
        if case .scanning(let fraction) = phase, fraction == nil, !reduceMotion {
            return true
        }
        return false
    }

    private func updateSpin(_ spinning: Bool) {
        if spinning {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                spinAngle = 360
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                spinAngle = 0
            }
        }
    }

    private var accessibilityText: Text {
        switch phase {
        case .idle:
            return Text("Ready to scan")
        case .scanning(let fraction):
            if let fraction {
                return Text("Scanning, \(Int(fraction * 100)) percent")
            }
            return Text("Scanning")
        case .result(let value, let unit, let caption):
            var parts = [value]
            if let unit { parts.append(unit) }
            if let caption { parts.append(caption) }
            return Text(parts.joined(separator: " "))
        }
    }
}

#Preview("Scan ring phases") {
    HStack(spacing: 32) {
        ScanRing(phase: .idle)
        ScanRing(phase: .scanning(fraction: nil))
        ScanRing(phase: .scanning(fraction: 0.63), tint: ModuleTint.cleanup.fallbackColor)
        ScanRing(phase: .result(value: "12.4", unit: "GB", caption: "can be freed"),
                 tint: ModuleTint.cleanup.fallbackColor)
    }
    .padding(32)
}

#Preview("Animated") {
    struct Demo: View {
        @State private var phase: ScanRing.Phase = .idle
        var body: some View {
            VStack(spacing: 24) {
                ScanRing(phase: phase)
                HStack {
                    Button("Idle") { phase = .idle }
                    Button("Indeterminate") { phase = .scanning(fraction: nil) }
                    Button("40%") { phase = .scanning(fraction: 0.4) }
                    Button("Result") { phase = .result(value: "8.1", unit: "GB", caption: "found") }
                }
            }
            .padding(32)
        }
    }
    return Demo()
}
