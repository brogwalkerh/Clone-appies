import Foundation
import CleanerCore

/// Built-in scanner so the CLI is exercisable on any tree: walks `--home` and
/// reports `*.tmp`, `*.log` and the contents of `.Trash`.
struct DemoScanner: CleanerScanner {
    static let id = "cli.demo"

    static let temporaryFiles = FindingCategory(id: "cli.demo.temporaryFiles",
                                                displayName: "Temporary Files", module: .cleanup)
    static let logFiles = FindingCategory(id: "cli.demo.logFiles",
                                          displayName: "Log Files", module: .cleanup)
    static let trash = FindingCategory(id: "cli.demo.trash",
                                       displayName: "Trash", module: .cleanup)

    var displayName: String { "Demo (temp files, logs, Trash)" }
    var module: ModuleID { .cleanup }

    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Finding, any Error>.makeStream()
        let scanner = self
        let task = Task {
            do {
                try await scanner.performScan(context) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func performScan(_ context: ScanContext, yield: @Sendable (Finding) -> Void) async throws {
        let walker = FileWalker(fileSystem: context.fileSystem, protectedPaths: context.protectedPaths)
        let trashURL = context.home.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL
        let trashPath = trashURL.path
        let trashPrefix = trashPath.hasSuffix("/") ? trashPath : trashPath + "/"

        for try await (url, attributes) in walker.walk(context.home) {
            try Task.checkCancellation()
            let standardized = url.standardizedFileURL
            let path = standardized.path
            if path == trashPath || path.hasPrefix(trashPrefix) { continue }
            guard !attributes.isDirectory, !attributes.isSymlink else { continue }
            let category: FindingCategory
            let detail: String
            switch url.pathExtension.lowercased() {
            case "tmp":
                category = Self.temporaryFiles
                detail = "Temporary file"
            case "log":
                category = Self.logFiles
                detail = "Log file"
            default:
                continue
            }
            yield(Finding(path: standardized, sizeBytes: attributes.sizeBytes, category: category,
                          scannerID: Self.id, risk: .safe, detail: detail,
                          modifiedAt: attributes.modifiedAt))
        }

        guard context.fileSystem.exists(trashURL),
              let children = try? context.fileSystem.children(of: trashURL) else { return }
        for child in children.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard let attributes = try? context.fileSystem.attributes(of: child) else { continue }
            let size: Int64
            if attributes.isDirectory, !attributes.isSymlink {
                size = (try? await walker.directorySize(child)) ?? 0
            } else {
                size = attributes.sizeBytes
            }
            yield(Finding(path: child.standardizedFileURL, sizeBytes: size, category: Self.trash,
                          scannerID: Self.id, risk: .caution, detail: "In Trash",
                          modifiedAt: attributes.modifiedAt, isDirectory: attributes.isDirectory))
        }
    }
}
