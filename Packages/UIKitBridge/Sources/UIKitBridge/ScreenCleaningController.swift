import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// Screen Cleaning Mode (PLAN.md §3.11): black borderless windows on every
/// display at `.screenSaver` level, a session event tap that swallows all
/// keyboard and mouse input, a countdown, and a hold-⌘-for-2-seconds escape.
///
/// Requires Accessibility (`AXIsProcessTrusted`). Without it `begin` shows an
/// explanation with an "Open System Settings" button and does nothing else, so
/// the user is never locked behind a screen we cannot unlock.
@MainActor
public final class ScreenCleaningController {
    public static let shared = ScreenCleaningController()

    /// How long ⌘ must be held before the session ends.
    public static let exitHoldDuration: Duration = .seconds(2)

    public private(set) var isActive = false

    private let model = ScreenCleaningModel()
    private var windows: [NSWindow] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var sessionTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var endDate: Date = .distantPast

    private init() {}

    // MARK: Public API

    public func begin(duration: Duration = .seconds(120)) {
        guard !isActive else { return }
        guard AXIsProcessTrusted() else {
            presentAccessibilityExplanation()
            return
        }
        guard let tap = installEventTap() else {
            presentAccessibilityExplanation()
            return
        }

        isActive = true
        eventTap = tap
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        endDate = Date().addingTimeInterval(seconds)
        model.remainingSeconds = Int(seconds.rounded(.up))
        model.holdProgress = 0

        windows = NSScreen.screens.map { makeWindow(for: $0) }
        for window in windows {
            window.orderFrontRegardless()
        }
        NSApp.activate()
        NSCursor.hide()

        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = max(0, Int(self.endDate.timeIntervalSinceNow.rounded(.up)))
                self.model.remainingSeconds = remaining
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        sessionTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.end()
        }
    }

    public func end() {
        guard isActive else { return }
        isActive = false

        sessionTask?.cancel()
        countdownTask?.cancel()
        holdTask?.cancel()
        sessionTask = nil
        countdownTask = nil
        holdTask = nil

        removeEventTap()

        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()

        NSCursor.unhide()
        model.holdProgress = 0
        NSApp.activate()
    }

    // MARK: Windows

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false,
                              screen: screen)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: ScreenCleaningOverlay(model: model))
        window.setFrame(screen.frame, display: true)
        return window
    }

    // MARK: Event tap

    private static let interestingEvents: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    private func installEventTap() -> CFMachPort? {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        // The callback is a C function pointer: no captures, so it rehydrates
        // the controller from `userInfo`. The tap is serviced on the main run
        // loop, which is why `assumeIsolated` is sound here.
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<ScreenCleaningController>.fromOpaque(info).takeUnretainedValue()
            let flags = event.flags
            let swallow = MainActor.assumeIsolated {
                controller.handle(type: type, flags: flags)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: ScreenCleaningController.interestingEvents,
                                          callback: callback,
                                          userInfo: userInfo),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source
        return tap
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Returns `true` when the event must be swallowed.
    private func handle(type: CGEventType, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables taps whose callback was slow; turn it back on.
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        case .flagsChanged:
            if flags.contains(.maskCommand) {
                startHoldTimer()
            } else {
                cancelHoldTimer()
            }
            return true
        default:
            return true
        }
    }

    private func startHoldTimer() {
        guard holdTask == nil else { return }
        let hold = ScreenCleaningController.exitHoldDuration
        let holdSeconds = Double(hold.components.seconds) + Double(hold.components.attoseconds) / 1e18
        holdTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                guard let self else { return }
                self.model.holdProgress = min(1, elapsed / holdSeconds)
                if elapsed >= holdSeconds {
                    self.end()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func cancelHoldTimer() {
        holdTask?.cancel()
        holdTask = nil
        model.holdProgress = 0
    }

    // MARK: Accessibility explanation

    private func presentAccessibilityExplanation() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = """
            Screen Cleaning Mode locks the keyboard and trackpad while you wipe the display. \
            macOS only allows that for apps with Accessibility access. \
            Turn on Mac Cleaner Menu under System Settings › Privacy & Security › Accessibility, then try again.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Overlay

/// Countdown state shared by every display's overlay.
@MainActor
@Observable
public final class ScreenCleaningModel {
    public var remainingSeconds: Int = 0
    /// 0...1 while ⌘ is held, 0 otherwise.
    public var holdProgress: Double = 0

    public init() {}

    convenience init(remainingSeconds: Int, holdProgress: Double) {
        self.init()
        self.remainingSeconds = remainingSeconds
        self.holdProgress = holdProgress
    }

    /// `mm:ss`.
    public var countdownText: String {
        ScreenCleaningModel.format(seconds: remainingSeconds)
    }

    static func format(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

/// The content of each black window. Dim text on pure black so fingerprints
/// and smudges stay visible while wiping.
public struct ScreenCleaningOverlay: View {
    private let model: ScreenCleaningModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: ScreenCleaningModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Text(model.countdownText)
                    .font(.system(size: 120, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .accessibilityLabel(Text("\(model.remainingSeconds) seconds remaining"))
                Text("Keyboard and trackpad are locked. Hold ⌘ for 2 seconds to exit.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.4))
                ProgressView(value: model.holdProgress)
                    .progressViewStyle(.linear)
                    .tint(.white.opacity(0.6))
                    .frame(width: 220)
                    .opacity(model.holdProgress > 0 ? 1 : 0)
                    .accessibilityHidden(model.holdProgress == 0)
                    .accessibilityLabel(Text("Keep holding Command to exit"))
            }
            .padding(48)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("Screen Cleaning overlay") {
    ScreenCleaningOverlay(model: ScreenCleaningModel(remainingSeconds: 97, holdProgress: 0.4))
        .frame(width: 800, height: 500)
}
