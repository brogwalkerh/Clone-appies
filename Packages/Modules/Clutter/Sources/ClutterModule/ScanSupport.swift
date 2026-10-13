import Foundation
import CleanerCore

/// Categories shared by the Clutter scanners.
enum ClutterCategory {
    static let largeFiles = FindingCategory(id: "clutter.largeFiles", displayName: "Large Files", module: .clutter)
    static let oldFiles = FindingCategory(id: "clutter.oldFiles", displayName: "Old Files", module: .clutter)
    static let duplicates = FindingCategory(id: "clutter.duplicates", displayName: "Duplicate Files", module: .clutter)
    static let similarImages = FindingCategory(id: "clutter.similarImages", displayName: "Similar Images", module: .clutter)
    static let downloads = FindingCategory(id: "clutter.downloads", displayName: "Downloads", module: .clutter)
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

/// Runs `body`, returning nil when it throws anything but cancellation, which
/// is rethrown so a cancelled scan stops promptly instead of grinding on.
func attempt<T>(_ body: () throws -> T) throws -> T? {
    do {
        return try body()
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return nil
    }
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

    /// Walker for listing. Package bundles are yielded but not entered.
    var listingWalker: FileWalker {
        FileWalker(fileSystem: fileSystem, followsSymlinks: false,
                   skipsPackageContents: true, protectedPaths: protectedPaths)
    }

    func homePath(_ relative: String) -> URL {
        home.appendingPathComponent(relative).standardizedFileURL
    }

    /// Children of `url`, or `[]` when it is missing or unreadable.
    func readableChildren(of url: URL) -> [URL] {
        guard fileSystem.exists(url) else { return [] }
        return (try? fileSystem.children(of: url)) ?? []
    }

    /// Existing, readable directories for the home-relative `roots`, with
    /// duplicates and roots nested inside another root removed so that no
    /// file is visited twice.
    func scanRoots(_ roots: [String]) -> [URL] {
        var kept: [URL] = []
        for url in roots.map(homePath).sorted(by: { $0.path < $1.path }) {
            if shouldSkip(url) { continue }
            guard let attributes = try? fileSystem.attributes(of: url),
                  attributes.isDirectory else { continue }
            let path = url.path
            if kept.contains(where: { $0.path == path || path.hasPrefix($0.path + "/") }) { continue }
            kept.append(url)
        }
        return kept
    }

    /// Visits every regular file under `roots` (package contents skipped,
    /// symlinks and directories not reported, ignored/protected paths dropped).
    func forEachRegularFile(under roots: [URL],
                            _ body: (URL, FileAttributes) async throws -> Void) async throws {
        for root in roots {
            for try await (url, attributes) in listingWalker.walk(root) {
                try Task.checkCancellation()
                guard !attributes.isDirectory, !attributes.isSymlink else { continue }
                let standardized = url.standardizedFileURL
                if shouldSkip(standardized) { continue }
                try await body(standardized, attributes)
            }
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
