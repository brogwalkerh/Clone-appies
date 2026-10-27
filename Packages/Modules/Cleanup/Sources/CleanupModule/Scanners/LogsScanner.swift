import Foundation
import CleanerCore

/// Log files under `~/Library/Logs` (and rotated logs in sandboxed app
/// containers), plus crash reports from `DiagnosticReports` as their own
/// category.
public struct LogsScanner: CleanerScanner {
    public static let id = "cleanup.logs"
    public static let crashReportsCategoryID = "cleanup.crashReports"
    public let displayName = "Log Files"
    public let module = ModuleID.cleanup

    private let rules: CleanupRules

    public init(rules: CleanupRules = .shared) {
        self.rules = rules
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let rules = self.rules
        return makeFindingStream { emitter in
            let logsRoot = context.homePath("Library/Logs")
            let diagnostics = logsRoot.appendingPathComponent("DiagnosticReports")
            let logDetail = rules.rule(id: "logs")?.description
            let crashDetail = rules.rule(id: "crashReports")?.description

            for child in context.readableChildren(of: logsRoot) {
                try Task.checkCancellation()
                if context.shouldSkip(child) { continue }
                if child.standardizedFileURL.path == diagnostics.standardizedFileURL.path {
                    for report in context.readableChildren(of: child) {
                        try Task.checkCancellation()
                        if let finding = await context.finding(at: report, category: CleanupCategory.crashReports,
                                                               scannerID: Self.id, risk: .safe, detail: crashDetail) {
                            emitter.emit(finding)
                        }
                    }
                    continue
                }
                try await Self.emitFiles(under: child, context: context, detail: logDetail,
                                         filter: { _ in true }, emitter: emitter)
            }

            // Rotated logs inside sandboxed app containers.
            if let containerRule = rules.rule(id: "logs.containers") {
                for relative in containerRule.relativePaths {
                    for root in rules.expand(relative, home: context.home, fileSystem: context.fileSystem) {
                        try await Self.emitFiles(under: root, context: context, detail: containerRule.description,
                                                 filter: Self.isLogFile, emitter: emitter)
                    }
                }
            }
        }
    }

    /// `*.log`, `*.log.N`, `*.gz` and similar rotations.
    static func isLogFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".log") || name.hasSuffix(".gz") || name.hasSuffix(".bz2") || name.hasSuffix(".zst") {
            return true
        }
        // "app.log.1", "app.log.20260101"
        if let range = name.range(of: ".log.") {
            let suffix = name[range.upperBound...]
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
        return false
    }

    private static func emitFiles(under root: URL, context: ScanContext, detail: String?,
                                  filter: @Sendable (URL) -> Bool, emitter: FindingEmitter) async throws {
        guard let attributes = try? context.fileSystem.attributes(of: root) else { return }
        if !attributes.isDirectory {
            guard !attributes.isSymlink, filter(root), !context.shouldSkip(root) else { return }
            emitter.emit(Finding(path: root.standardizedFileURL, sizeBytes: attributes.sizeBytes,
                                 category: CleanupCategory.logs, scannerID: id, risk: .safe,
                                 detail: detail, modifiedAt: attributes.modifiedAt, isDirectory: false))
            return
        }
        for try await (url, attrs) in context.listingWalker.walk(root) {
            try Task.checkCancellation()
            guard !attrs.isDirectory, !attrs.isSymlink, filter(url), !context.shouldSkip(url) else { continue }
            emitter.emit(Finding(path: url.standardizedFileURL, sizeBytes: attrs.sizeBytes,
                                 category: CleanupCategory.logs, scannerID: id, risk: .safe,
                                 detail: detail, modifiedAt: attrs.modifiedAt, isDirectory: false))
        }
    }
}
