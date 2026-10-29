import Foundation
import CleanerHashing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct SignatureUpdateResult: Sendable, Hashable {
    public let version: String
    public let filesUpdated: Int
    public let bytes: Int64

    public init(version: String, filesUpdated: Int, bytes: Int64) {
        self.version = version
        self.filesUpdated = filesUpdated
        self.bytes = bytes
    }
}

/// `<baseURL>/manifest.json`.
public struct SignatureFeedManifest: Codable, Sendable, Hashable {
    public struct File: Codable, Sendable, Hashable {
        public let name: String
        public let sha256: String
        public let bytes: Int64

        public init(name: String, sha256: String, bytes: Int64) {
            self.name = name
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    public let version: String
    public let files: [File]

    public init(version: String, files: [File]) {
        self.version = version
        self.files = files
    }
}

public enum SignatureUpdateError: Error, Sendable, Hashable, LocalizedError {
    case badResponse(URL, statusCode: Int)
    case invalidManifest(String)
    case invalidFileName(String)
    case digestMismatch(name: String, expected: String, actual: String)
    case sizeMismatch(name: String, expected: Int64, actual: Int64)
    case replaceFailed(name: String, reason: String)
    case removeFailed(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let url, let code): "\(url.lastPathComponent): HTTP \(code)"
        case .invalidManifest(let reason): "Invalid signature manifest: \(reason)"
        case .invalidFileName(let name): "Manifest names an unexpected file: \(name)"
        case .digestMismatch(let name, _, _): "\(name) failed SHA-256 verification"
        case .sizeMismatch(let name, let expected, let actual): "\(name) is \(actual) bytes, expected \(expected)"
        case .replaceFailed(let name, let reason): "Could not install \(name): \(reason)"
        case .removeFailed(let name, let reason): "Could not remove withdrawn \(name): \(reason)"
        }
    }
}

/// Downloads signature files from our own feed (ADR 0006).
///
/// Only files whose manifest SHA-256 differs from the local copy are fetched.
/// Every download is verified before anything is installed; files are
/// written to a staging directory and then swapped into `destination` with
/// `rename(2)`, so a reader never sees a partial file. Files an earlier
/// update installed (listed in `<destination>/INSTALLED`) that the manifest
/// no longer lists are then deleted, so withdrawn signatures stop loading;
/// files the updater never installed, such as a user's own `.ign2`
/// allowlist, are never touched. The manifest version is stored in
/// `<destination>/VERSION`.
public struct SignatureUpdater: Sendable {
    public static let manifestFileName = "manifest.json"
    public static let versionFileName = "VERSION"
    /// Names of the files the last successful update installed, one per line.
    public static let installedFileName = "INSTALLED"
    public static let allowedExtensions = SignatureDatabase.supportedExtensions

    public let baseURL: URL
    public let destination: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared, destination: URL) {
        self.baseURL = baseURL
        self.session = session
        self.destination = destination.standardizedFileURL
    }

    /// Version from the last successful update, or nil.
    public func currentVersion() -> String? {
        guard let data = try? Data(contentsOf: destination.appendingPathComponent(Self.versionFileName)) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func update() async throws -> SignatureUpdateResult {
        let manifestData = try await fetch(Self.manifestFileName)
        let manifest: SignatureFeedManifest
        do {
            manifest = try JSONDecoder().decode(SignatureFeedManifest.self, from: manifestData)
        } catch {
            throw SignatureUpdateError.invalidManifest("\(error)")
        }
        guard !manifest.version.isEmpty else { throw SignatureUpdateError.invalidManifest("empty version") }
        for file in manifest.files {
            try Self.validate(name: file.name)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var pending: [(name: String, staged: URL, bytes: Int64)] = []
        for file in manifest.files {
            let expected = file.sha256.lowercased()
            let local = destination.appendingPathComponent(file.name)
            if let existing = try? Data(contentsOf: local), SHA256.hexString(SHA256.hash(existing)) == expected {
                continue
            }
            let data = try await fetch(file.name)
            let actual = SHA256.hexString(SHA256.hash(data))
            guard actual == expected else {
                throw SignatureUpdateError.digestMismatch(name: file.name, expected: expected, actual: actual)
            }
            if file.bytes > 0, Int64(data.count) != file.bytes {
                throw SignatureUpdateError.sizeMismatch(name: file.name, expected: file.bytes, actual: Int64(data.count))
            }
            let staged = staging.appendingPathComponent(file.name)
            try data.write(to: staged, options: .atomic)
            pending.append((file.name, staged, Int64(data.count)))
        }

        for item in pending {
            try Self.atomicReplace(item.staged, with: destination.appendingPathComponent(item.name), name: item.name)
        }
        let listed = Set(manifest.files.map(\.name))
        try removeWithdrawnFiles(installedNames().subtracting(listed))
        try Data(listed.sorted().joined(separator: "\n").utf8)
            .write(to: destination.appendingPathComponent(Self.installedFileName), options: .atomic)
        let versionFile = destination.appendingPathComponent(Self.versionFileName)
        try Data(manifest.version.utf8).write(to: versionFile, options: .atomic)
        return SignatureUpdateResult(version: manifest.version, filesUpdated: pending.count,
                                     bytes: pending.reduce(0) { $0 + $1.bytes })
    }

    // MARK: - Implementation

    private func fetch(_ name: String) async throws -> Data {
        let url = baseURL.appendingPathComponent(name)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SignatureUpdateError.badResponse(url, statusCode: http.statusCode)
        }
        return data
    }

    /// What the previous update installed. Missing (first update, or a
    /// destination from before this list existed) means nothing is removed.
    private func installedNames() -> Set<String> {
        let url = destination.appendingPathComponent(Self.installedFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }

    /// Deletes the named regular files from `destination`. Names that fail the
    /// manifest's own name rules (a tampered INSTALLED file) are ignored.
    private func removeWithdrawnFiles(_ names: Set<String>) throws {
        let fm = FileManager.default
        for name in names.sorted() {
            guard (try? Self.validate(name: name)) != nil else { continue }
            let url = destination.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            do {
                try fm.removeItem(at: url)
            } catch {
                throw SignatureUpdateError.removeFailed(name: name, reason: "\(error)")
            }
        }
    }

    /// Manifest entries must be bare file names with a signature extension.
    static func validate(name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."),
              name != Self.versionFileName, name != Self.manifestFileName,
              allowedExtensions.contains((name as NSString).pathExtension.lowercased()) else {
            throw SignatureUpdateError.invalidFileName(name)
        }
    }

    private static func atomicReplace(_ source: URL, with target: URL, name: String) throws {
        if rename(source.path, target.path) != 0 {
            throw SignatureUpdateError.replaceFailed(name: name, reason: String(cString: strerror(errno)))
        }
    }
}
