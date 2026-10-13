import Foundation

/// Fans scanners out over a bounded `TaskGroup`, filters and de-duplicates
/// their findings and publishes a single event stream.
public actor ScanCoordinator {
    private let scanners: [any Scanner]
    private let maxConcurrency: Int
    private var runningTask: Task<Void, Never>?

    public init(scanners: [any Scanner], maxConcurrency: Int = 4) {
        self.scanners = scanners
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Runs all scanners concurrently, de-duplicates findings by standardized path,
    /// drops any finding under a protected path or matching the ignore list, and
    /// yields events. Finishes with `.completed`.
    ///
    /// Calling `run` while a previous run is still in flight cancels that run.
    public func run(_ context: ScanContext) -> AsyncStream<ScanEvent> {
        runningTask?.cancel()
        let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .unbounded)
        let scanners = self.scanners
        let maxConcurrency = self.maxConcurrency
        let task = Task.detached(priority: .utility) {
            await Self.execute(scanners: scanners, maxConcurrency: maxConcurrency,
                               context: context, continuation: continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
        runningTask = task
        return stream
    }

    public func cancel() {
        runningTask?.cancel()
    }

    // MARK: - Implementation

    private static func execute(scanners: [any Scanner], maxConcurrency: Int,
                                context: ScanContext,
                                continuation: AsyncStream<ScanEvent>.Continuation) async {
        let clock = ContinuousClock()
        let start = clock.now
        let sink = FindingSink(continuation: continuation,
                               protectedPaths: context.protectedPaths,
                               ignoreList: context.ignoreList)

        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for scanner in scanners {
                if Task.isCancelled { break }
                if running >= maxConcurrency {
                    await group.next()
                    running -= 1
                }
                group.addTask {
                    await runScanner(scanner, context: context, sink: sink)
                }
                running += 1
            }
            await group.waitForAll()
        }

        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let summary = await sink.summary(duration: seconds)
        continuation.yield(.completed(summary))
        continuation.finish()
    }

    private static func runScanner(_ scanner: any Scanner, context: ScanContext,
                                   sink: FindingSink) async {
        let id = type(of: scanner).id
        await sink.emit(.started(scannerID: id))
        var count = 0
        var bytes: Int64 = 0
        do {
            for try await finding in scanner.scan(context) {
                if Task.isCancelled { break }
                if await sink.accept(finding) {
                    count += 1
                    bytes += finding.sizeBytes
                }
            }
            await sink.emit(.finished(scannerID: id, count: count, bytes: bytes))
        } catch is CancellationError {
            await sink.emit(.finished(scannerID: id, count: count, bytes: bytes))
        } catch {
            await sink.emit(.failed(scannerID: id, message: String(describing: error)))
        }
    }
}

/// Serializes event emission and holds the de-duplication / totals state.
private actor FindingSink {
    private let continuation: AsyncStream<ScanEvent>.Continuation
    private let protectedPaths: ProtectedPaths
    private let ignoreList: IgnoreList
    private var seen: Set<String> = []
    private var totalFindings = 0
    private var totalBytes: Int64 = 0
    private var byCategory: [String: Int64] = [:]

    init(continuation: AsyncStream<ScanEvent>.Continuation,
         protectedPaths: ProtectedPaths, ignoreList: IgnoreList) {
        self.continuation = continuation
        self.protectedPaths = protectedPaths
        self.ignoreList = ignoreList
    }

    func emit(_ event: ScanEvent) {
        continuation.yield(event)
    }

    /// Returns true when the finding was accepted and published.
    func accept(_ finding: Finding) -> Bool {
        let url = finding.path
        if protectedPaths.isProtected(url) { return false }
        if ignoreList.contains(url) { return false }
        let key = url.standardizedFileURL.path
        guard seen.insert(key).inserted else { return false }
        totalFindings += 1
        totalBytes += finding.sizeBytes
        byCategory[finding.category.id, default: 0] += finding.sizeBytes
        continuation.yield(.finding(finding))
        return true
    }

    func summary(duration: TimeInterval) -> ScanSummary {
        ScanSummary(totalFindings: totalFindings, totalBytes: totalBytes,
                    byCategory: byCategory, duration: duration)
    }
}
