import Foundation
import CleanerCore

public struct QuarantineRecord: Codable, Sendable, Hashable {
    public let threat: Threat
    /// Where the item now lives inside the quarantine; nil once restored or when the move failed.
    public let storedAt: URL?
    public let succeeded: Bool
    public let error: String?
    /// POSIX mode bits the item had before quarantine (0o644 when unknown).
    public let originalPermissions: Int16

    public init(threat: Threat, storedAt: URL?, succeeded: Bool, error: String?,
                originalPermissions: Int16 = 0o644) {
        self.threat = threat
        self.storedAt = storedAt
        self.succeeded = succeeded
        self.error = error
        self.originalPermissions = originalPermissions
    }

    private enum CodingKeys: String, CodingKey {
        case threat, storedAt, succeeded, error, originalPermissions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threat = try container.decode(Threat.self, forKey: .threat)
        storedAt = try container.decodeIfPresent(URL.self, forKey: .storedAt)
        succeeded = try container.decode(Bool.self, forKey: .succeeded)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        originalPermissions = try container.decodeIfPresent(Int16.self, forKey: .originalPermissions) ?? 0o644
    }

    /// Mode to apply on restore: 0o755 for directories and anything that had
    /// an execute bit, 0o644 otherwise.
    public var restoredPermissions: Int16 {
        (threat.isDirectory || originalPermissions & 0o111 != 0) ? 0o755 : 0o644
    }
}

public struct QuarantineManifest: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let date: Date
    public let records: [QuarantineRecord]

    public init(id: UUID = UUID(), date: Date = .now, records: [QuarantineRecord]) {
        self.id = id
        self.date = date
        self.records = records
    }
}

/// Quarantine instead of Trash. Layout:
/// `<directory>/<manifest id>/manifest.json` plus, per item,
/// `<directory>/<manifest id>/<threat id>/<original filename>` with mode 000.
public actor ThreatQuarantine {
    public static let manifestFileName = "manifest.json"

    private let directory: URL
    private let fileSystem: any FileSystem

    public init(directory: URL, fileSystem: any FileSystem = LocalFileSystem()) {
        self.directory = directory.standardizedFileURL
        self.fileSystem = fileSystem
    }

    /// Moves each threat into the quarantine and strips its permissions.
    /// Never throws: per-item failures are recorded in the manifest.
    public func quarantine(_ threats: [Threat]) async -> QuarantineManifest {
        let id = UUID()
        // Whole seconds: the manifest is stored as ISO 8601 and must round-trip.
        let date = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let manifestDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        var records: [QuarantineRecord] = []
        do {
            try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        } catch {
            let records = threats.map {
                QuarantineRecord(threat: $0, storedAt: nil, succeeded: false,
                                 error: "Cannot create quarantine directory: \(error)")
            }
            return QuarantineManifest(id: id, date: date, records: records)
        }

        for threat in threats {
            let source = threat.path.standardizedFileURL
            let permissions = Self.permissions(of: source) ?? 0o644
            if PathHelpers.isDescendant(source, of: directory) {
                records.append(QuarantineRecord(threat: threat, storedAt: nil, succeeded: false,
                                                error: "Already in quarantine", originalPermissions: permissions))
                continue
            }
            if ProtectedPaths.default.isProtected(source) {
                records.append(QuarantineRecord(threat: threat, storedAt: nil, succeeded: false,
                                                error: "Protected path", originalPermissions: permissions))
                continue
            }
            let itemDirectory = manifestDirectory.appendingPathComponent(threat.id.uuidString, isDirectory: true)
            let destination = itemDirectory.appendingPathComponent(source.lastPathComponent)
            do {
                guard fileSystem.exists(source) else { throw FileSystemError.notFound(source) }
                try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: destination)
                try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: destination.path)
                records.append(QuarantineRecord(threat: threat, storedAt: destination, succeeded: true,
                                                error: nil, originalPermissions: permissions))
            } catch {
                try? FileManager.default.removeItem(at: itemDirectory)
                records.append(QuarantineRecord(threat: threat, storedAt: nil, succeeded: false,
                                                error: "\(error)", originalPermissions: permissions))
            }
        }
        let manifest = QuarantineManifest(id: id, date: date, records: records)
        try? Self.write(manifest, to: manifestDirectory)
        return manifest
    }

    /// Moves the manifest's items back to their original paths and resets
    /// their permissions. Records with no stored item (never quarantined, or
    /// already restored) are returned as-is; a record whose earlier restore
    /// failed still has `storedAt` and is retried.
    public func restore(_ manifest: QuarantineManifest) async -> [QuarantineRecord] {
        var results: [QuarantineRecord] = []
        for record in manifest.records {
            guard let stored = record.storedAt else {
                results.append(record)
                continue
            }
            let destination = record.threat.path.standardizedFileURL
            do {
                guard FileManager.default.fileExists(atPath: stored.path) else { throw FileSystemError.notFound(stored) }
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw FileSystemError.unreadable(destination, "An item already exists at the original path")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: stored, to: destination)
                try? FileManager.default.setAttributes([.posixPermissions: Int(record.restoredPermissions)],
                                                       ofItemAtPath: destination.path)
                try? FileManager.default.removeItem(at: stored.deletingLastPathComponent())
                results.append(QuarantineRecord(threat: record.threat, storedAt: nil, succeeded: true, error: nil,
                                                originalPermissions: record.originalPermissions))
            } catch {
                results.append(QuarantineRecord(threat: record.threat, storedAt: stored, succeeded: false,
                                                error: "\(error)", originalPermissions: record.originalPermissions))
            }
        }
        let manifestDirectory = directory.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        let remaining = results.filter { $0.storedAt != nil }
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: manifestDirectory)
        } else {
            try? Self.write(QuarantineManifest(id: manifest.id, date: manifest.date, records: remaining),
                            to: manifestDirectory)
        }
        return results
    }

    /// Every manifest on disk, newest first. Throws only when the quarantine
    /// directory exists but cannot be listed.
    public func list() async throws -> [QuarantineManifest] {
        guard fileSystem.exists(directory) else { return [] }
        var manifests: [QuarantineManifest] = []
        for child in try fileSystem.children(of: directory) {
            let file = child.appendingPathComponent(Self.manifestFileName)
            guard let data = try? fileSystem.contents(of: file),
                  let manifest = try? Self.decoder.decode(QuarantineManifest.self, from: data) else { continue }
            manifests.append(manifest)
        }
        return manifests.sorted { $0.date > $1.date }
    }

    /// Permanently deletes manifests older than `olderThan` seconds (0 = all).
    /// Returns the number of manifests removed.
    public func purge(olderThan: TimeInterval) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-olderThan)
        var removed = 0
        for manifest in try await list() where manifest.date <= cutoff {
            let manifestDirectory = directory.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
            Self.makeDeletable(manifestDirectory)
            try FileManager.default.removeItem(at: manifestDirectory)
            removed += 1
        }
        return removed
    }

    // MARK: - Implementation

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func write(_ manifest: QuarantineManifest, to manifestDirectory: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: manifestDirectory.appendingPathComponent(manifestFileName), options: .atomic)
    }

    static func permissions(of url: URL) -> Int16? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        switch attributes[.posixPermissions] {
        case let number as NSNumber: return number.int16Value
        case let value as Int: return Int16(truncatingIfNeeded: value)
        case let value as Int16: return value
        case let value as UInt16: return Int16(truncatingIfNeeded: value)
        default: return nil
        }
    }

    /// Restores owner read/write (and search) bits below `root` so that
    /// `removeItem` can traverse items that were chmod 000.
    private static func makeDeletable(_ root: URL) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return }
        try? fm.setAttributes([.posixPermissions: isDirectory.boolValue ? 0o700 : 0o600], ofItemAtPath: root.path)
        guard isDirectory.boolValue, let children = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for child in children {
            makeDeletable(root.appendingPathComponent(child))
        }
    }
}
