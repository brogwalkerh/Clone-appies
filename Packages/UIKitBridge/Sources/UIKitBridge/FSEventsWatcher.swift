import CoreServices
import Foundation

/// Owns one `FSEventStream` on a dedicated thread with its own run loop and
/// forwards every callback into an `AsyncStream` of `Message`s.
///
/// Why a thread: FSEvents delivers through the run loop it is scheduled on,
/// and the main run loop of a menu bar agent is busy enough. The thread does
/// nothing but service the stream; everything heavier (hashing, heuristics)
/// happens in `ProtectionMonitor` on the Swift concurrency pool.
///
/// Lifetime: the thread's block keeps `self` alive until the run loop exits,
/// and `self` keeps `sink` alive, so the unretained context pointer handed to
/// `FSEventStreamCreate` can never dangle. `stop()` is safe from any thread
/// and idempotent; after the stream is torn down the continuation finishes.
final class FSEventsWatcher: @unchecked Sendable {
    struct Event: Sendable, Hashable {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    enum Message: Sendable {
        case started
        case events([Event])
        case failed(String)
    }

    /// Target of the C callback. `Unmanaged` hands FSEvents an unretained
    /// pointer to this object; `continuation` is itself `Sendable`.
    private final class Sink: Sendable {
        let continuation: AsyncStream<Message>.Continuation
        init(continuation: AsyncStream<Message>.Continuation) {
            self.continuation = continuation
        }
    }

    static let threadName = "com.example.maccleaner.fsevents"

    private let sink: Sink
    private let paths: [String]
    private let latency: CFTimeInterval
    private let createFlags: FSEventStreamCreateFlags

    // Guarded by `lock`: written by the watcher thread, read by `stop()`.
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var shouldStop = false
    private var started = false

    init(paths: [String], latency: CFTimeInterval, continuation: AsyncStream<Message>.Continuation) {
        self.sink = Sink(continuation: continuation)
        self.paths = paths
        self.latency = latency
        self.createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer)
    }

    /// Spawns the thread. Calling twice is a no-op.
    func start() {
        let shouldSpawn: Bool = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        guard shouldSpawn else { return }
        let thread = Thread { [self] in
            self.run()
        }
        thread.name = FSEventsWatcher.threadName
        thread.qualityOfService = .utility
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Asks the thread to tear the stream down and exit. Returns at once; the
    /// stream's continuation finishes when the thread has unwound. If the
    /// thread never started the continuation is finished here instead.
    func stop() {
        let (loop, hadStarted): (CFRunLoop?, Bool) = lock.withLock {
            shouldStop = true
            return (runLoop, started)
        }
        if let loop {
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
        } else if !hadStarted {
            sink.continuation.finish()
        }
    }

    // MARK: Watcher thread

    private func run() {
        let loop = CFRunLoopGetCurrent()
        let alreadyStopped: Bool = lock.withLock {
            runLoop = loop
            return shouldStop
        }
        if alreadyStopped {
            sink.continuation.finish()
            return
        }

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(sink).toOpaque(),
                                           retain: nil,
                                           release: nil,
                                           copyDescription: nil)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault,
                                               FSEventsWatcher.callback,
                                               &context,
                                               paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency,
                                               createFlags) else {
            sink.continuation.yield(.failed("FSEventStreamCreate failed for \(paths.count) paths"))
            sink.continuation.finish()
            return
        }

        // TODO(macOS27): FSEventStreamScheduleWithRunLoop is deprecated since
        // macOS 13 in favour of FSEventStreamSetDispatchQueue. It still works on
        // 26; if the 27 SDK removes it, switch to a private serial queue and
        // drop the run loop below.
        FSEventStreamScheduleWithRunLoop(stream, loop, CFRunLoopMode.defaultMode.rawValue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            sink.continuation.yield(.failed("FSEventStreamStart failed"))
            sink.continuation.finish()
            return
        }
        sink.continuation.yield(.started)

        // Bounded iterations rather than one CFRunLoopRun(): the stop flag is
        // re-checked every second even if a wake-up is missed.
        while !lock.withLock({ shouldStop }) {
            _ = CFRunLoopRunInMode(.defaultMode, 1.0, false)
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        lock.withLock { runLoop = nil }
        sink.continuation.finish()
    }

    /// The C callback: no captures, just unpacks the CF array (UseCFTypes) and
    /// the parallel flags buffer, then yields one batch.
    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
        let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let paths = (cfPaths as NSArray).compactMap { $0 as? String }
        let count = min(numEvents, paths.count)
        guard count > 0 else { return }
        var events: [Event] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            events.append(Event(path: paths[index], flags: eventFlags[index]))
        }
        sink.continuation.yield(.events(events))
    }
}
