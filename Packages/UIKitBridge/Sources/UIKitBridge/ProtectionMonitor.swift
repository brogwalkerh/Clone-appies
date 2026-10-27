import CleanerCore
import CleanerHashing
import CoreServices
import Foundation
import ProtectionModule

public enum ProtectionEvent: Sendable {
    case started
    case threat(Threat)
    case scanned(URL)
    case stopped(reason: String)
}

/// FSEvents-based real-time watch over the places malware lands first
/// (PLAN.md §3.3 "Fallback"). Endpoint Security is a later entitlement.
///
/// Pipeline, per file event:
/// 1. `FSEventsWatcher` (own thread + run loop, latency 1 s, file-level
///    events) batches (path, flags) into an `AsyncStream`.
/// 2. The actor debounces per path (2 s of quiet) with `PathDebouncer`, so a
///    download in progress is hashed once when it settles.
/// 3. At most `maxInFlight` inspections run on detached utility tasks; extra
///    paths wait in a bounded FIFO. Each inspection `lstat`s the file, skips
///    directories, symlinks, empty files and anything over `maxFileSize`,
///    hashes it (MD5 + SHA-256 in one streaming pass), runs `PatternMatcher`
///    on executables (Mach-O, PE, ELF, `#!` scripts) with chunk overlap,
///    checks `SignatureDatabase.match`, runs `Heuristics` on launchd plists and
///    executables, and annotates hits with the `com.apple.quarantine` origin.
/// 4. `.threat` / `.scanned` are yielded on the stream returned by `start()`.
///
/// `kFSEventStreamEventFlagMustScanSubDirs` (and dropped-event flags) trigger
/// a top-level re-enqueue of that directory, capped at `maxDirectoryEntries`.
/// Every table is bounded; see the constants below. Call `stop()` before
/// discarding the monitor: the watcher thread holds no reference to the actor,
/// but it keeps running until told to stop.
public actor ProtectionMonitor {
    /// ~/Downloads, /Applications, ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons.
    public static var defaultPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Downloads", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
        ]
    }

    public static let maxFileSize: Int64 = 200_000_000
    public static let debounceWindow: TimeInterval = 2
    public static let fsEventsLatency: CFTimeInterval = 1.0
    /// Concurrent inspections; each holds one 1 MiB read buffer plus overlap.
    static let maxInFlight = 4
    /// Paths waiting for an inspection slot; the oldest is dropped past this.
    static let maxBacklog = 2048
    /// Children re-enqueued for one MustScanSubDirs directory.
    static let maxDirectoryEntries = 5000
    /// Output stream buffer; the agent drains it continuously.
    static let outputBuffer = 512

    private let paths: [URL]
    private let configuration: FileInspector.Configuration

    private var watcher: FSEventsWatcher?
    private var consumer: Task<Void, Never>?
    private var output: AsyncStream<ProtectionEvent>.Continuation?
    private var debouncer = PathDebouncer(window: ProtectionMonitor.debounceWindow)
    private var timers: [String: Task<Void, Never>] = [:]
    private var inFlight = 0
    private var backlog: [String] = []
    private var isRunning = false
    /// Bumped on every start/stop so late callbacks from a previous run are ignored.
    private var generation = 0
    private let clock: ContinuousClock
    private let epoch: ContinuousClock.Instant

    public init(paths: [URL] = ProtectionMonitor.defaultPaths,
                database: SignatureDatabase,
                verifier: any CodeSignatureVerifier) {
        let clock = ContinuousClock()
        self.paths = paths
        self.clock = clock
        self.epoch = clock.now
        self.configuration = FileInspector.Configuration(database: database,
                                                         verifier: verifier,
                                                         home: FileManager.default.homeDirectoryForCurrentUser,
                                                         maxFileSize: ProtectionMonitor.maxFileSize)
    }

    // MARK: Lifecycle

    /// Starts watching and returns the event stream. A second call while
    /// running stops the first run (its stream ends with `.stopped`) and
    /// starts afresh.
    public func start() -> AsyncStream<ProtectionEvent> {
        if isRunning { stop(reason: "restarted") }

        let (stream, continuation) = AsyncStream.makeStream(of: ProtectionEvent.self,
                                                            bufferingPolicy: .bufferingNewest(ProtectionMonitor.outputBuffer))
        output = continuation
        isRunning = true
        generation += 1
        let run = generation

        let watchedPaths = paths
            .filter { !configuration.protectedPaths.isProtected($0) }
            .map { $0.standardizedFileURL.path(percentEncoded: false) }
        let (messages, messageContinuation) = AsyncStream.makeStream(of: FSEventsWatcher.Message.self,
                                                                     bufferingPolicy: .bufferingNewest(256))
        let watcher = FSEventsWatcher(paths: watchedPaths,
                                      latency: ProtectionMonitor.fsEventsLatency,
                                      continuation: messageContinuation)
        self.watcher = watcher

        consumer = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                await self.handle(message, run: run)
            }
            await self?.watcherEnded(run: run)
        }
        watcher.start()
        return stream
    }

    public func stop() {
        stop(reason: "stopped")
    }

    private func stop(reason: String) {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        watcher?.stop()
        watcher = nil
        consumer?.cancel()
        consumer = nil
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        debouncer.removeAll()
        backlog.removeAll()
        output?.yield(.stopped(reason: reason))
        output?.finish()
        output = nil
    }

    private func watcherEnded(run: Int) {
        guard isRunning, run == generation else { return }
        stop(reason: "FSEvents stream ended")
    }

    // MARK: Event intake

    private func handle(_ message: FSEventsWatcher.Message, run: Int) {
        guard isRunning, run == generation else { return }
        switch message {
        case .started:
            output?.yield(.started)
        case .failed(let reason):
            stop(reason: reason)
        case .events(let events):
            for event in events {
                switch ProtectionMonitor.disposition(for: event.flags) {
                case .ignore:
                    continue
                case .scanFile:
                    enqueue(event.path)
                case .rescanDirectory:
                    rescanTopLevel(of: event.path, run: run)
                }
            }
        }
    }

    enum EventDisposition: Sendable, Hashable {
        case ignore, scanFile, rescanDirectory
    }

    /// Pure flag triage (tested). Directories and symlinks are never hashed;
    /// a bare removal has nothing to look at; coalescing or dropped events
    /// mean "look at the whole directory again".
    static func disposition(for flags: FSEventStreamEventFlags) -> EventDisposition {
        let bits = Int(flags)
        if bits & (kFSEventStreamEventFlagMustScanSubDirs
                   | kFSEventStreamEventFlagUserDropped
                   | kFSEventStreamEventFlagKernelDropped) != 0 {
            return .rescanDirectory
        }
        if bits & (kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink) != 0 {
            return .ignore
        }
        let touching = kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemModified
            | kFSEventStreamEventFlagItemRenamed
            | kFSEventStreamEventFlagItemXattrMod
            | kFSEventStreamEventFlagItemChangeOwner
            | kFSEventStreamEventFlagItemFinderInfoMod
            | kFSEventStreamEventFlagItemInodeMetaMod
        if bits & kFSEventStreamEventFlagItemRemoved != 0, bits & touching == 0 {
            return .ignore
        }
        return .scanFile
    }

    private func now() -> TimeInterval {
        (clock.now - epoch).totalSeconds
    }

    private func enqueue(_ path: String) {
        switch debouncer.record(path, at: now()) {
        case .schedule:
            armTimer(for: path, after: debouncer.window)
        case .alreadyScheduled:
            break
        case .scanImmediately:
            dispatch(path)
        }
    }

    private func armTimer(for path: String, after seconds: TimeInterval) {
        timers[path]?.cancel()
        let run = generation
        timers[path] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.timerFired(for: path, run: run)
        }
    }

    private func timerFired(for path: String, run: Int) {
        guard isRunning, run == generation else { return }
        switch debouncer.flush(path, at: now()) {
        case .scan:
            timers[path] = nil
            dispatch(path)
        case .wait(let remaining):
            armTimer(for: path, after: remaining)
        case .nothingPending:
            timers[path] = nil
        }
    }

    /// Lists the directory on a utility task and feeds regular files back
    /// through the debouncer (so a burst for the same folder coalesces).
    private func rescanTopLevel(of directory: String, run: Int) {
        let fileSystem = configuration.fileSystem
        let limit = ProtectionMonitor.maxDirectoryEntries
        Task.detached(priority: .utility) { [weak self] in
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            guard let children = try? fileSystem.children(of: url) else { return }
            var files: [String] = []
            for child in children.prefix(limit) {
                guard let attributes = try? fileSystem.attributes(of: child),
                      !attributes.isDirectory, !attributes.isSymlink else { continue }
                files.append(child.path(percentEncoded: false))
            }
            await self?.enqueueAll(files, run: run)
        }
    }

    private func enqueueAll(_ files: [String], run: Int) {
        guard isRunning, run == generation else { return }
        for file in files { enqueue(file) }
    }

    // MARK: Inspection

    private func dispatch(_ path: String) {
        guard isRunning else { return }
        guard inFlight < ProtectionMonitor.maxInFlight else {
            if backlog.count >= ProtectionMonitor.maxBacklog {
                backlog.removeFirst()
            }
            backlog.append(path)
            return
        }
        inFlight += 1
        let configuration = self.configuration
        let run = generation
        Task.detached(priority: .utility) { [weak self] in
            let events = await FileInspector.inspect(path: path, configuration: configuration)
            await self?.inspectionFinished(events, run: run)
        }
    }

    private func inspectionFinished(_ events: [ProtectionEvent], run: Int) {
        inFlight = max(0, inFlight - 1)
        guard isRunning, run == generation else { return }
        for event in events {
            output?.yield(event)
        }
        if !backlog.isEmpty {
            dispatch(backlog.removeFirst())
        }
    }
}

// MARK: - FileInspector

/// The per-file work, kept out of the actor so it runs on the cooperative
/// pool's utility tasks. Everything here is synchronous file I/O plus the
/// async heuristics; nothing touches the main thread.
enum FileInspector {
    struct Configuration: Sendable {
        let database: SignatureDatabase
        let matchers: [ExecutableKind: PatternMatcher]
        let heuristics: Heuristics
        let verifier: any CodeSignatureVerifier
        let fileSystem: LocalFileSystem
        let protectedPaths: ProtectedPaths
        let home: URL
        let maxFileSize: Int64

        init(database: SignatureDatabase, verifier: any CodeSignatureVerifier, home: URL, maxFileSize: Int64) {
            self.database = database
            self.matchers = FileInspector.matchers(for: database.patterns)
            self.heuristics = Heuristics()
            self.verifier = verifier
            self.fileSystem = LocalFileSystem()
            self.protectedPaths = .default
            self.home = home
            self.maxFileSize = maxFileSize
        }
    }

    /// ClamAV `.ndb` target types we scan: 1 PE, 6 ELF, 9 Mach-O. Scripts have
    /// no dedicated target and only see the "any" (0) patterns.
    enum ExecutableKind: Sendable, Hashable, CaseIterable {
        case machO, pe, elf, script

        var ndbTarget: Int? {
            switch self {
            case .machO: return 9
            case .pe: return 1
            case .elf: return 6
            case .script: return nil
            }
        }

        /// Magic-byte detection (pure, tested). Accepts both Mach-O byte orders
        /// and fat binaries.
        static func detect(magic: some Collection<UInt8>) -> ExecutableKind? {
            let bytes = Array(magic.prefix(4))
            guard bytes.count >= 2 else { return nil }
            if bytes[0] == 0x23, bytes[1] == 0x21 { return .script }          // "#!"
            if bytes[0] == 0x4D, bytes[1] == 0x5A { return .pe }              // "MZ"
            guard bytes.count == 4 else { return nil }
            if bytes == [0x7F, 0x45, 0x4C, 0x46] { return .elf }
            switch bytes {
            case [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF],
                 [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],
                 [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]:
                return .machO
            default:
                return nil
            }
        }
    }

    /// One matcher per executable kind over the "any" patterns plus that
    /// kind's own; kinds with nothing to match are left out entirely.
    static func matchers(for patterns: [HexPattern]) -> [ExecutableKind: PatternMatcher] {
        var result: [ExecutableKind: PatternMatcher] = [:]
        for kind in ExecutableKind.allCases {
            let subset = patterns.filter { $0.target == 0 || $0.target == kind.ndbTarget }
            if !subset.isEmpty {
                result[kind] = PatternMatcher(patterns: subset)
            }
        }
        return result
    }

    static let chunkSize = 1 << 20

    struct Digest: Sendable {
        let md5: String
        let sha256: String
        let bytesRead: Int64
        let kind: ExecutableKind?
        let patternMatches: Set<String>
    }

    static func inspect(path: String, configuration: Configuration) async -> [ProtectionEvent] {
        let url = URL(fileURLWithPath: path)
        guard !configuration.protectedPaths.isProtected(url) else { return [] }
        guard let attributes = try? configuration.fileSystem.attributes(of: url) else { return [] }   // gone again
        guard !attributes.isDirectory, !attributes.isSymlink else { return [] }
        let logicalSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int(clamping: attributes.sizeBytes))
        guard logicalSize > 0, logicalSize <= configuration.maxFileSize else { return [] }

        guard let digest = hashAndMatch(url: url, logicalSize: logicalSize,
                                        matchers: configuration.matchers, maxFileSize: configuration.maxFileSize) else {
            return []
        }

        var threats: [Threat] = []
        if let name = configuration.database.match(md5: digest.md5, sha256: digest.sha256, size: digest.bytesRead) {
            threats.append(Threat(path: url, name: name, kind: .signature, severity: .critical,
                                  detail: "Matches known malware hash", sizeBytes: attributes.sizeBytes, isDirectory: false))
        }
        for name in digest.patternMatches.sorted() {
            threats.append(Threat(path: url, name: name, kind: .signature, severity: .high,
                                  detail: "Matches known malware body pattern", sizeBytes: attributes.sizeBytes, isDirectory: false))
        }

        let context = HeuristicContext(fileSystem: configuration.fileSystem,
                                       home: configuration.home,
                                       signatureVerifier: configuration.verifier,
                                       now: Date())
        if isLaunchdPlist(url) {
            threats += await configuration.heuristics.evaluate(launchAgentPlist: url, context: context)
        }
        if digest.kind != nil {
            threats += await configuration.heuristics.evaluate(executable: url, attributes: attributes, context: context)
        }

        guard !threats.isEmpty else { return [.scanned(url)] }

        let quarantine = QuarantineAttribute.read(path: path)
        var seen = Set<String>()
        return threats
            .filter { seen.insert($0.name).inserted }
            .map { .threat(annotate($0, with: quarantine)) }
    }

    /// `~/Library/LaunchAgents/x.plist`, `/Library/LaunchDaemons/x.plist`.
    static func isLaunchdPlist(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "plist" else { return false }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent == "LaunchAgents" || parent == "LaunchDaemons"
    }

    /// Appends "Downloaded from <agent>" to the detail when the quarantine
    /// attribute names a source. `Threat` is immutable, so a copy is built.
    static func annotate(_ threat: Threat, with quarantine: QuarantineAttribute?) -> Threat {
        guard let download = quarantine?.downloadDescription else { return threat }
        let detail = threat.detail.isEmpty ? download : "\(threat.detail) • \(download)"
        return Threat(id: threat.id, path: threat.path, name: threat.name, kind: threat.kind,
                      severity: threat.severity, detail: detail, sizeBytes: threat.sizeBytes,
                      isDirectory: threat.isDirectory)
    }

    /// One streaming pass: MD5 and SHA-256 over every chunk; for executables
    /// the matcher sees each chunk prefixed with the previous chunk's last
    /// `maxPatternLength` bytes so a pattern straddling a boundary still hits.
    /// Returns nil when the file cannot be read or grows past `maxFileSize`
    /// while being read.
    static func hashAndMatch(url: URL, logicalSize: Int64,
                             matchers: [ExecutableKind: PatternMatcher], maxFileSize: Int64) -> Digest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var md5 = StreamingMD5()
        var sha256 = StreamingSHA256()
        var kind: ExecutableKind?
        var matcher: PatternMatcher?
        var carry = Data()
        var offset: Int64 = 0
        var matches = Set<String>()
        var isFirstChunk = true

        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }

            if isFirstChunk {
                isFirstChunk = false
                kind = ExecutableKind.detect(magic: chunk.prefix(4))
                matcher = kind.flatMap { matchers[$0] }
            }

            md5.update(chunk)
            sha256.update(chunk)

            if let matcher {
                let window = carry.isEmpty ? chunk : carry + chunk
                let windowOffset = offset - Int64(carry.count)
                for name in matcher.matches(in: window, fileSize: logicalSize, chunkOffset: windowOffset) {
                    matches.insert(name)
                }
                let overlap = min(matcher.maxPatternLength, window.count)
                carry = overlap > 0 ? Data(window.suffix(overlap)) : Data()
            }

            offset += Int64(chunk.count)
            if offset > maxFileSize { return nil }
        }

        return Digest(md5: MD5.hexString(md5.finalize()),
                      sha256: SHA256.hexString(sha256.finalize()),
                      bytesRead: offset,
                      kind: kind,
                      patternMatches: matches)
    }
}
