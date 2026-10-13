import Foundation

/// Per-path debounce bookkeeping for the Protection Monitor (pure, tested).
///
/// FSEvents reports a download as a burst of create/modify/rename events over
/// a few seconds. The monitor wants to hash the file once, after it has gone
/// quiet, so every event for a path pushes that path's due time out by
/// `window`. One timer per path is enough: when it fires, `flush` either says
/// "scan now" or hands back how much longer to wait.
///
/// Time is a plain monotonic `TimeInterval` so tests do not need a clock.
/// Pending paths are capped at `capacity`; past the cap a *new* path is scanned
/// immediately rather than queued, which bounds memory during a huge copy
/// without silently dropping anything.
struct PathDebouncer: Sendable {
    enum RecordDecision: Sendable, Hashable {
        /// First event for this path: the caller must schedule a timer for `window`.
        case schedule
        /// A timer is already pending; its flush will see the new due time.
        case alreadyScheduled
        /// The pending table is full; scan this path right away, nothing was recorded.
        case scanImmediately
    }

    enum FlushDecision: Sendable, Hashable {
        /// Quiet for a full window: scan, entry removed.
        case scan
        /// Touched again meanwhile: re-arm the timer for this long.
        case wait(TimeInterval)
        /// Nothing pending for the path (already flushed or never recorded).
        case nothingPending
    }

    let window: TimeInterval
    let capacity: Int
    private var dueTimes: [String: TimeInterval] = [:]

    init(window: TimeInterval = 2, capacity: Int = 4096) {
        self.window = max(0, window)
        self.capacity = max(1, capacity)
    }

    var pendingCount: Int { dueTimes.count }

    func isPending(_ path: String) -> Bool { dueTimes[path] != nil }

    mutating func record(_ path: String, at now: TimeInterval) -> RecordDecision {
        if dueTimes[path] != nil {
            dueTimes[path] = now + window
            return .alreadyScheduled
        }
        guard dueTimes.count < capacity else { return .scanImmediately }
        dueTimes[path] = now + window
        return .schedule
    }

    mutating func flush(_ path: String, at now: TimeInterval) -> FlushDecision {
        guard let due = dueTimes[path] else { return .nothingPending }
        let remaining = due - now
        // Timers fire a hair early; anything inside 10 ms counts as quiet.
        if remaining <= 0.01 {
            dueTimes.removeValue(forKey: path)
            return .scan
        }
        return .wait(remaining)
    }

    mutating func cancel(_ path: String) {
        dueTimes.removeValue(forKey: path)
    }

    mutating func removeAll() {
        dueTimes.removeAll()
    }
}
