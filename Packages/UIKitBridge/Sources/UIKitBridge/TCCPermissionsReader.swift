import AppKit
import Foundation
import ProtectionModule
import SQLite3

/// `PermissionsReader` over the two TCC databases:
/// `~/Library/Application Support/com.apple.TCC/TCC.db` (per-user grants:
/// camera, microphone, automation, ...) and
/// `/Library/Application Support/com.apple.TCC/TCC.db` (system grants: Full
/// Disk Access, Accessibility, Screen Recording, Input Monitoring).
///
/// Both are opened read-only with SQLite3; both need Full Disk Access to even
/// open. When neither can be opened `grants()` returns `[]` (not an error) and
/// `lastError` carries the reason, so the UI can prompt for FDA instead of
/// showing a failure banner. Rows are merged with user rows winning for the
/// same (service, client) pair; `kTCCService*` names map to `PrivacyService`
/// through `PrivacyService.mapTCCService`, unknown services are dropped.
///
/// Schema drift: macOS 11+ stores the decision in `auth_value`; older
/// databases use `allowed`. The new column set is tried first and the legacy
/// one on prepare failure. All I/O runs on a detached utility task.
public struct TCCPermissionsReader: PermissionsReader {
    public struct ReadError: Error, Sendable, Hashable, CustomStringConvertible {
        public enum Kind: String, Sendable, Hashable {
            /// `sqlite3_open_v2` failed: almost always missing Full Disk Access.
            case cannotOpen
            /// Opened but the `access` table could not be read with either schema.
            case queryFailed
        }
        public let kind: Kind
        public let database: URL
        public let message: String

        /// True when granting Full Disk Access to this process is the likely fix.
        public var needsFullDiskAccess: Bool { kind == .cannotOpen }

        public var description: String {
            "\(kind.rawValue): \(database.path(percentEncoded: false)) — \(message)"
        }
    }

    /// One `access` row, before service mapping and name lookup (pure, tested).
    struct Row: Sendable, Hashable {
        let service: String
        let client: String
        let clientType: Int
        let authValue: Int
        /// Unix seconds, as stored; nil when the column is NULL.
        let lastModified: Int64?
        let legacySchema: Bool

        /// `auth_value`: 0 denied, 1 unknown/prompt, 2 allowed, 3 limited
        /// (macOS 14+ partial Photos/Contacts access: still a grant).
        /// Legacy `allowed`: plain 0/1.
        var granted: Bool {
            TCCPermissionsReader.granted(authValue: authValue, legacySchema: legacySchema)
        }
    }

    public static let userDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
    public static let systemDatabase = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")

    private let errorBox = ErrorBox()
    private let userDatabase: URL
    private let systemDatabase: URL

    public init() {
        self.init(userDatabase: TCCPermissionsReader.userDatabase, systemDatabase: TCCPermissionsReader.systemDatabase)
    }

    init(userDatabase: URL, systemDatabase: URL) {
        self.userDatabase = userDatabase
        self.systemDatabase = systemDatabase
    }

    /// The failure from the most recent `grants()` call, nil after a clean read.
    /// When both databases fail the user one is reported (its message names FDA).
    public var lastError: ReadError? {
        get async { await errorBox.error }
    }

    public func grants() async throws -> [PermissionGrant] {
        let userDB = userDatabase
        let systemDB = systemDatabase
        let (rows, error) = await Task.detached(priority: .utility) { () -> ([Row], ReadError?) in
            let user = TCCPermissionsReader.readRows(at: userDB)
            let system = TCCPermissionsReader.readRows(at: systemDB)
            let merged = TCCPermissionsReader.merge(user: user.rows, system: system.rows)
            // Prefer the user DB's error: it is the one a user-level FDA grant fixes.
            let error: ReadError?
            switch (user.error, system.error) {
            case (nil, nil): error = nil
            case let (userError?, _): error = userError
            case let (nil, systemError?): error = systemError
            }
            return (merged, error)
        }.value
        await errorBox.set(error)

        let names = await TCCPermissionsReader.resolveNames(for: rows)
        return rows.compactMap { row -> PermissionGrant? in
            guard let service = PrivacyService.mapTCCService(row.service) else { return nil }
            return PermissionGrant(service: service,
                                   clientID: row.client,
                                   clientName: names[row.client],
                                   granted: row.granted,
                                   lastModified: row.lastModified.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }

    // MARK: Pure helpers (tested)

    static func granted(authValue: Int, legacySchema: Bool) -> Bool {
        if legacySchema { return authValue != 0 }
        return authValue == 2 || authValue == 3
    }

    /// Union keyed by (service, client); a user row replaces a system row for
    /// the same key. Output order: user rows first in input order, then the
    /// remaining system rows.
    static func merge(user: [Row], system: [Row]) -> [Row] {
        var seen = Set<String>()
        var merged: [Row] = []
        merged.reserveCapacity(user.count + system.count)
        for row in user where seen.insert(key(for: row)).inserted {
            merged.append(row)
        }
        for row in system where seen.insert(key(for: row)).inserted {
            merged.append(row)
        }
        return merged
    }

    static func key(for row: Row) -> String { "\(row.service):\(row.client)" }

    // MARK: SQLite3 (nonisolated, synchronous, off the main thread)

    private static let modernQuery = "SELECT service, client, client_type, auth_value, last_modified FROM access"
    private static let legacyQuery = "SELECT service, client, client_type, allowed, last_modified FROM access"
    /// Upper bound on rows per database; TCC tables are a few hundred rows.
    private static let maxRows = 10_000

    static func readRows(at url: URL) -> (rows: [Row], error: ReadError?) {
        let path = url.path(percentEncoded: false)
        var handle: OpaquePointer?
        // TODO(macOS27): tccd keeps TCC.db in WAL mode; a read-only open needs the
        // -wal/-shm siblings readable too. If the 27 SDK's TCC moves to a
        // different journal mode or location, revisit the open flags.
        let openStatus = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed (\(openStatus))"
            if let handle { sqlite3_close(handle) }
            return ([], ReadError(kind: .cannotOpen, database: url, message: message))
        }
        defer { sqlite3_close(db) }

        if let rows = query(db, sql: modernQuery, legacy: false) {
            return (rows, nil)
        }
        if let rows = query(db, sql: legacyQuery, legacy: true) {
            return (rows, nil)
        }
        return ([], ReadError(kind: .queryFailed, database: url, message: String(cString: sqlite3_errmsg(db))))
    }

    /// Runs one of the two schema variants. Returns nil when the statement
    /// cannot be prepared (missing column) so the caller can try the other.
    private static func query(_ db: OpaquePointer, sql: String, legacy: Bool) -> [Row]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while rows.count < maxRows {
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else { break }
            guard let service = text(statement, column: 0), let client = text(statement, column: 1) else { continue }
            let clientType = Int(sqlite3_column_int(statement, 2))
            let authValue = Int(sqlite3_column_int(statement, 3))
            let lastModified: Int64? = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4)
            rows.append(Row(service: service, client: client, clientType: clientType,
                            authValue: authValue, lastModified: lastModified, legacySchema: legacy))
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    // MARK: Display names

    /// client_type 0 is a bundle identifier (resolved through Launch Services),
    /// 1 is an absolute path. `NSWorkspace.urlForApplication` is a Launch
    /// Services lookup, done on the main actor like `AppIconProvider`; the
    /// `displayName` reads happen afterwards on a utility task.
    private static func resolveNames(for rows: [Row]) async -> [String: String] {
        let bundleIDs = Set(rows.filter { $0.clientType == 0 }.map(\.client))
        let paths = Set(rows.filter { $0.clientType == 1 }.map(\.client))

        let bundleURLs: [String: URL] = await MainActor.run {
            var urls: [String: URL] = [:]
            for identifier in bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                    urls[identifier] = url
                }
            }
            return urls
        }

        return await Task.detached(priority: .utility) { () -> [String: String] in
            let fileManager = FileManager.default
            var names: [String: String] = [:]
            for (identifier, url) in bundleURLs {
                names[identifier] = fileManager.displayName(atPath: url.path(percentEncoded: false))
            }
            for path in paths where fileManager.fileExists(atPath: path) {
                names[path] = fileManager.displayName(atPath: path)
            }
            return names
        }.value
    }
}

/// Holds the last error across `grants()` calls; the reader itself is a value.
private actor ErrorBox {
    var error: TCCPermissionsReader.ReadError?

    func set(_ error: TCCPermissionsReader.ReadError?) {
        self.error = error
    }
}
