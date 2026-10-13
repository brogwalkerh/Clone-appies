import Foundation
import CleanerCore

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

/// Same bridge for `Threat` streams.
func makeThreatStream(
    _ body: @escaping @Sendable (AsyncThrowingStream<Threat, any Error>.Continuation) async throws -> Void
) -> AsyncThrowingStream<Threat, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Threat, any Error>.makeStream()
    let task = Task.detached(priority: .utility) {
        do {
            try await body(continuation)
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

    /// Walker for size computation. Package contents are included so that
    /// bundles are sized correctly.
    var sizingWalker: FileWalker {
        FileWalker(fileSystem: fileSystem, followsSymlinks: false,
                   skipsPackageContents: false, protectedPaths: protectedPaths)
    }

    func homePath(_ relative: String) -> URL {
        home.appendingPathComponent(relative).standardizedFileURL
    }

    /// Children of `url`, or `[]` when it is missing or unreadable.
    func readableChildren(of url: URL) -> [URL] {
        guard fileSystem.exists(url) else { return [] }
        return (try? fileSystem.children(of: url)) ?? []
    }

    /// Existing child directories of `url` (symlinks excluded).
    func childDirectories(of url: URL) -> [URL] {
        readableChildren(of: url).filter { child in
            guard let attributes = try? fileSystem.attributes(of: child) else { return false }
            return attributes.isDirectory && !attributes.isSymlink
        }
    }

    /// Builds a finding for `url`, sizing directories recursively. Returns nil
    /// when the item is missing, unreadable, ignored or protected.
    func finding(at url: URL, category: FindingCategory, scannerID: String,
                 risk: RiskLevel, detail: String?) async -> Finding? {
        let url = url.standardizedFileURL
        if shouldSkip(url) { return nil }
        guard let attributes = try? fileSystem.attributes(of: url) else { return nil }
        let size: Int64
        if attributes.isDirectory {
            guard let total = try? await sizingWalker.directorySize(url) else { return nil }
            size = total
        } else if attributes.isSymlink {
            size = 0
        } else {
            size = attributes.sizeBytes
        }
        return Finding(path: url, sizeBytes: size, category: category, scannerID: scannerID,
                       risk: risk, detail: detail, modifiedAt: attributes.modifiedAt,
                       isDirectory: attributes.isDirectory)
    }
}

/// Path helpers shared by heuristics and scope resolution.
enum PathHelpers {
    /// True when `url` equals `ancestor` or lies below it (component aware).
    static func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = ancestor.standardizedFileURL.path
        if base == "/" { return true }
        return path == base || path.hasPrefix(base + "/")
    }

    /// Path components after `ancestor` (empty when not a descendant).
    static func components(of url: URL, below ancestor: URL) -> [String] {
        let path = url.standardizedFileURL.pathComponents
        let base = ancestor.standardizedFileURL.pathComponents
        guard path.count >= base.count, Array(path[0..<base.count]) == base else { return [] }
        return Array(path[base.count...])
    }

    /// True when any component of `path` (other than "." and "..") starts with ".".
    static func hasHiddenComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }
}
