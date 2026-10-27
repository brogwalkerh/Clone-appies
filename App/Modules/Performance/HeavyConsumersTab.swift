import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CleanerCore
import DesignSystem
import PerformanceModule
import UIKitBridge

/// Polls `DarwinProcessSampler` and ranks the result with `HeavyConsumersRanker`.
/// Shared by Heavy Consumers and Hung Apps; `PerformanceView` runs `poll(every:)`
/// in a `.task` that is cancelled when neither tab is visible.
@MainActor
@Observable
final class ProcessMonitor {
    private(set) var samples: [ProcessSample] = []
    private(set) var heavy: [ProcessSample] = []
    private(set) var hung: [ProcessSample] = []
    private(set) var lastSampledAt: Date?
    private(set) var isSampling = false
    private(set) var lastError: String?

    private let sampler = DarwinProcessSampler()
    private let ranker = HeavyConsumersRanker()
    private var iconCache: [Int32: NSImage] = [:]

    init() {}

    func poll(every interval: Duration) async {
        while !Task.isCancelled {
            await sampleOnce()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    func sampleOnce() async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }
        do {
            let fresh = try await sampler.sample()
            samples = fresh
            heavy = ranker.rank(fresh)
            hung = ranker.hung(fresh)
            lastSampledAt = .now
            lastError = nil
            let live = Set(fresh.map(\.id))
            iconCache = iconCache.filter { live.contains($0.key) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The app's icon for a pid, or the generic executable icon for non-app processes.
    func icon(for sample: ProcessSample) -> NSImage {
        if let cached = iconCache[sample.id] { return cached }
        let image = NSRunningApplication(processIdentifier: sample.id)?.icon
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        iconCache[sample.id] = image
        return image
    }

    func runningApplication(for sample: ProcessSample) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: sample.id)
    }

    /// Polite quit. Falls back to SIGTERM for processes without an `NSRunningApplication`.
    @discardableResult
    func quit(_ sample: ProcessSample) -> Bool {
        if let app = runningApplication(for: sample) {
            return app.terminate()
        }
        return kill(sample.id, SIGTERM) == 0
    }

    @discardableResult
    func forceQuit(_ sample: ProcessSample) -> Bool {
        if let app = runningApplication(for: sample) {
            return app.forceTerminate()
        }
        return kill(sample.id, SIGKILL) == 0
    }
}

// MARK: - Heavy Consumers

struct HeavyConsumersTab: View {
    let monitor: ProcessMonitor
    let onError: @MainActor (String) -> Void

    @State private var forceQuitTarget: ProcessSample?

    var body: some View {
        Group {
            if monitor.samples.isEmpty, monitor.isSampling || monitor.lastSampledAt == nil {
                if let error = monitor.lastError {
                    EmptyState(title: "Could Not Read Processes",
                               message: error,
                               style: .symbol("exclamationmark.triangle"),
                               actionTitle: "Try Again") {
                        Task { await monitor.sampleOnce() }
                    }
                } else {
                    EmptyState.scanning("Sampling processes…",
                                        message: "CPU and memory are measured over a few seconds.")
                }
            } else if monitor.heavy.isEmpty {
                EmptyState.nothingFound("No Heavy Consumers",
                                        message: "Nothing is using more than 20% CPU or 1 GB of memory right now. This list refreshes every 3 seconds.")
            } else {
                List(monitor.heavy) { sample in
                    ProcessRow(sample: sample, monitor: monitor, showHungBadge: true) {
                        if !monitor.quit(sample) {
                            onError("\(sample.name) did not respond to Quit. Try Force Quit.")
                        }
                    } forceQuit: {
                        forceQuitTarget = sample
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .forceQuitConfirmation(target: $forceQuitTarget, monitor: monitor, onError: onError)
    }
}

// MARK: - Hung Apps

struct HungAppsTab: View {
    let monitor: ProcessMonitor
    let onError: @MainActor (String) -> Void

    @State private var forceQuitTarget: ProcessSample?

    var body: some View {
        Group {
            if monitor.lastSampledAt == nil {
                EmptyState.scanning("Checking for unresponsive apps…",
                                    message: "Each app is asked to respond within a second.")
            } else if monitor.hung.isEmpty {
                EmptyState.nothingFound("No unresponsive apps",
                                        message: "Every running app answered within a second. This check repeats every 3 seconds while you are here.")
            } else {
                List(monitor.hung) { sample in
                    ProcessRow(sample: sample, monitor: monitor, showHungBadge: false) {
                        if !monitor.quit(sample) {
                            onError("\(sample.name) did not respond to Quit. Try Force Quit.")
                        }
                    } forceQuit: {
                        forceQuitTarget = sample
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .forceQuitConfirmation(target: $forceQuitTarget, monitor: monitor, onError: onError)
    }
}

// MARK: - Row and confirmation

struct ProcessRow: View {
    let sample: ProcessSample
    let monitor: ProcessMonitor
    let showHungBadge: Bool
    let quit: @MainActor () -> Void
    let forceQuit: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: monitor.icon(for: sample))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(sample.name)
                        .lineLimit(1)
                    if sample.isSystem { PerformanceBadge(text: "System", color: .gray) }
                    if showHungBadge, sample.isResponsive == false {
                        PerformanceBadge(text: "Not responding", color: .red)
                    }
                }
                Text(sample.bundleIdentifier ?? "PID \(sample.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(sample.cpuPercent.formatted(.number.precision(.fractionLength(0))) + "% CPU")
                .monospacedDigit()
                .foregroundStyle(sample.cpuPercent >= 20 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 90, alignment: .trailing)
                .contentTransition(.numericText())

            Text(ByteFormatter.string(sample.residentBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
                .contentTransition(.numericText())

            if let energy = sample.energyImpact {
                Text("Energy \(energy.formatted(.number.precision(.fractionLength(0))))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .trailing)
            }

            Button("Quit") { quit() }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(sample.isSystem)
            Button("Force Quit") { forceQuit() }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(sample.isSystem)
        }
        .padding(.vertical, 3)
        .help(sample.isSystem ? "System processes are left alone; macOS restarts them anyway." : "")
        .accessibilityElement(children: .combine)
    }
}

private struct ForceQuitConfirmation: ViewModifier {
    @Binding var target: ProcessSample?
    let monitor: ProcessMonitor
    let onError: @MainActor (String) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Force quit \(target?.name ?? "this process")?",
                                   isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                                   titleVisibility: .visible,
                                   presenting: target) { sample in
            Button("Force Quit", role: .destructive) {
                if !monitor.forceQuit(sample) {
                    onError("\(sample.name) could not be force quit. It may belong to another user or already be gone.")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Unsaved changes in this app will be lost.")
        }
    }
}

private extension View {
    func forceQuitConfirmation(target: Binding<ProcessSample?>,
                               monitor: ProcessMonitor,
                               onError: @escaping @MainActor (String) -> Void) -> some View {
        modifier(ForceQuitConfirmation(target: target, monitor: monitor, onError: onError))
    }
}
