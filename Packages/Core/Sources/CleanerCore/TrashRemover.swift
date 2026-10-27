import Foundation

/// macOS: FileManager.trashItem. Linux: moves into XDG trash dir (~/.local/share/Trash/files) for test parity.
///
/// `remove` never stops at the first failure: every finding gets a
/// `RemovalRecord`, and failures are recorded with a message. `undo` moves each
/// successfully trashed item back from its recorded `trashedTo` location.
public struct TrashRemover: Remover {
    private let fileSystem: any FileSystem
    /// When set, items are moved here instead of using the system Trash. Used
    /// on Linux (XDG trash) and by tests on every platform.
    private let trashDirectory: URL?

    public init(fileSystem: any FileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
        #if canImport(Darwin)
        self.trashDirectory = nil
        #else
        self.trashDirectory = Self.xdgTrashFilesDirectory()
        #endif
    }

    /// Additional initializer that forces moves into `trashDirectory` on every
    /// platform (so tests never touch the real Trash).
    public init(fileSystem: any FileSystem = LocalFileSystem(), trashDirectory: URL) {
        self.fileSystem = fileSystem
        self.trashDirectory = trashDirectory.standardizedFileURL
    }

    public func remove(_ findings: [Finding], mode: RemovalMode,
                       progress: (@Sendable (Int, Int) -> Void)?) async throws -> RemovalManifest {
        let startedAt = Date.now
        var records: [RemovalRecord] = []
        records.reserveCapacity(findings.count)
        let total = findings.count
        for (index, finding) in findings.enumerated() {
            try Task.checkCancellation()
            let record: RemovalRecord
            switch mode {
            case .trash:
                record = trash(finding)
            case .permanent:
                record = removePermanently(finding)
            }
            records.append(record)
            progress?(index + 1, total)
            await Task.yield()
        }
        return RemovalManifest(startedAt: startedAt, mode: mode, records: records)
    }

    public func undo(_ manifest: RemovalManifest) async throws -> [RemovalRecord] {
        var results: [RemovalRecord] = []
        for record in manifest.records {
            try Task.checkCancellation()
            guard record.succeeded, let trashed = record.trashedTo else {
                results.append(RemovalRecord(finding: record.finding, trashedTo: record.trashedTo,
                                             succeeded: false,
                                             error: record.succeeded
                                                 ? "permanently removed; nothing to restore"
                                                 : "was not removed"))
                continue
            }
            let destination = record.finding.path
            let fm = FileManager.default
            do {
                guard fm.fileExists(atPath: trashed.path) || isSymlink(trashed) else {
                    throw RemovalError.notFound(trashed)
                }
                if fm.fileExists(atPath: destination.path) || isSymlink(destination) {
                    throw RemovalError.destinationExists(destination)
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: trashed, to: destination)
                removeTrashInfo(for: trashed)
                results.append(RemovalRecord(finding: record.finding, trashedTo: trashed,
                                             succeeded: true, error: nil))
            } catch {
                results.append(RemovalRecord(finding: record.finding, trashedTo: trashed,
                                             succeeded: false, error: String(describing: error)))
            }
        }
        return results
    }

    // MARK: - Trash

    private func trash(_ finding: Finding) -> RemovalRecord {
        let source = finding.path
        guard fileSystem.exists(source) || isSymlink(source) else {
            return RemovalRecord(finding: finding, trashedTo: nil, succeeded: false,
                                 error: RemovalError.notFound(source).description)
        }
        if let trashDirectory {
            return moveToTrashDirectory(finding, trashDirectory: trashDirectory)
        }
        #if canImport(Darwin)
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
            let trashedTo = (resulting as URL?)?.standardizedFileURL
            return RemovalRecord(finding: finding, trashedTo: trashedTo, succeeded: true, error: nil)
        } catch {
            return RemovalRecord(finding: finding, trashedTo: nil, succeeded: false,
                                 error: String(describing: error))
        }
        #else
        return RemovalRecord(finding: finding, trashedTo: nil, succeeded: false,
                             error: RemovalError.trashUnavailable("no trash directory").description)
        #endif
    }

    private func moveToTrashDirectory(_ finding: Finding, trashDirectory: URL) -> RemovalRecord {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let destination = Self.uniqueDestination(for: finding.path, in: trashDirectory)
            try fm.moveItem(at: finding.path, to: destination)
            writeTrashInfo(original: finding.path, trashed: destination)
            return RemovalRecord(finding: finding, trashedTo: destination, succeeded: true, error: nil)
        } catch {
            return RemovalRecord(finding: finding, trashedTo: nil, succeeded: false,
                                 error: String(describing: error))
        }
    }

    private func removePermanently(_ finding: Finding) -> RemovalRecord {
        let source = finding.path
        guard fileSystem.exists(source) || isSymlink(source) else {
            return RemovalRecord(finding: finding, trashedTo: nil, succeeded: false,
                                 error: RemovalError.notFound(source).description)
        }
        do {
            try FileManager.default.removeItem(at: source)
            return RemovalRecord(finding: finding, trashedTo: nil, succeeded: true, error: nil)
        } catch {
            return RemovalRecord(finding: finding, trashedTo: nil, succeeded: false,
                                 error: String(describing: error))
        }
    }

    // MARK: - Helpers

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileSystem.attributes(of: url).isSymlink) ?? false
    }

    static func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        let name = source.lastPathComponent.isEmpty ? "item" : source.lastPathComponent
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        while fm.fileExists(atPath: candidate.path) || Self.lexists(candidate) {
            let newName = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    private static func lexists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// `~/.local/share/Trash/files`, honoring `$XDG_DATA_HOME`.
    static func xdgTrashFilesDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        let dataHome: URL
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            dataHome = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            dataHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
        }
        return dataHome.appendingPathComponent("Trash/files", isDirectory: true)
    }

    /// Writes a minimal XDG `.trashinfo` next to the files directory when the
    /// trash directory follows the `Trash/files` layout. Best effort.
    private func writeTrashInfo(original: URL, trashed: URL) {
        guard trashed.deletingLastPathComponent().lastPathComponent == "files" else { return }
        let infoDir = trashed.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("info", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: infoDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let encodedPath = original.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? original.path
        let text = "[Trash Info]\nPath=\(encodedPath)\nDeletionDate=\(formatter.string(from: .now))\n"
        let infoURL = infoDir.appendingPathComponent(trashed.lastPathComponent + ".trashinfo")
        try? text.data(using: .utf8)?.write(to: infoURL)
    }

    private func removeTrashInfo(for trashed: URL) {
        guard trashed.deletingLastPathComponent().lastPathComponent == "files" else { return }
        let infoURL = trashed.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent(trashed.lastPathComponent + ".trashinfo")
        try? FileManager.default.removeItem(at: infoURL)
    }
}
