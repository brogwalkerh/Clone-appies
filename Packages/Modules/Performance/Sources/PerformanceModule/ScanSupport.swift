import Foundation
import CleanerCore

/// Categories shared by the Performance module.
enum PerformanceCategory {
    static let brokenLoginItems = FindingCategory(id: "performance.brokenLoginItems",
                                                  displayName: "Broken Login Items", module: .performance)
}

/// Hands findings from a scanner body to its stream.
struct FindingEmitter: Sendable {
    let continuation: AsyncThrowingStream<Finding, any Error>.Continuation

    func emit(_ finding: Finding) {
        continuation.yield(finding)
    }
}

/// Runs `body` on a detached task and bridges it to an `AsyncThrowingStream`.
/// Cancelling the stream cancels the body.
func makeFindingStream(
    _ body: @escaping @Sendable (FindingEmitter) async throws -> Void
) -> AsyncThrowingStream<Finding, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Finding, any Error>.makeStream()
    let task = Task.detached(priority: .utility) {
        do {
            try await body(FindingEmitter(continuation: continuation))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
}

extension ScanContext {
    /// True when the coordinator would drop `url` anyway: skip it early.
    func shouldSkip(_ url: URL) -> Bool {
        ignoreList.contains(url) || protectedPaths.isProtected(url)
    }
}
