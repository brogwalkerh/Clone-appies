import Foundation
import CleanerCore

/// ClamAV text formats (ADR 0006). Parsing is tolerant: malformed lines are
/// skipped and counted in `stats.skippedLines`.
public struct SignatureDatabase: Sendable {
    public struct Stats: Sendable, Hashable {
        public let hashSignatures: Int
        public let patternSignatures: Int
        public let allowlisted: Int
        public let skippedLines: Int

        public init(hashSignatures: Int, patternSignatures: Int, allowlisted: Int, skippedLines: Int) {
            self.hashSignatures = hashSignatures
            self.patternSignatures = patternSignatures
            self.allowlisted = allowlisted
            self.skippedLines = skippedLines
        }
    }

    struct HashEntry: Sendable, Hashable {
        /// nil when the signature's size field is "*".
        let size: Int64?
        let name: String
    }

    private var md5Entries: [String: [HashEntry]] = [:]
    private var sha256Entries: [String: [HashEntry]] = [:]
    private var patternList: [HexPattern] = []
    private var ignoredNames: Set<String> = []
    private var hashCount = 0
    private var skipped = 0

    public init() {}

    // MARK: Loading

    /// `md5:size:name` (size may be "*"). Extra trailing fields are ignored.
    public mutating func load(hdb text: String) {
        let parsed = parseHashes(text, digestLength: 32)
        for entry in parsed.entries { md5Entries[entry.digest, default: []].append(entry.entry) }
        hashCount += parsed.entries.count
        skipped += parsed.skipped
    }

    /// `sha256:size:name`.
    public mutating func load(hsb text: String) {
        let parsed = parseHashes(text, digestLength: 64)
        for entry in parsed.entries { sha256Entries[entry.digest, default: []].append(entry.entry) }
        hashCount += parsed.entries.count
        skipped += parsed.skipped
    }

    /// `name:target:offset:hexpattern`. Offset is "*", an integer, or "EOF-n".
    /// Patterns using alternation or other unsupported syntax are skipped.
    public mutating func load(ndb text: String) {
        for line in Self.lines(of: text) {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty,
                  let target = Int(fields[1]), target >= 0,
                  let offset = Self.parseOffset(fields[2]),
                  let tokens = try? HexPatternParser.parse(fields[3]) else {
                skipped += 1
                continue
            }
            patternList.append(HexPattern(name: fields[0], target: target, offset: offset, tokens: tokens))
        }
    }

    /// One signature name per line. Legacy `.ign` lines (`db:line:name`)
    /// are accepted by taking the last field.
    public mutating func load(ign2 text: String) {
        for line in Self.lines(of: text) {
            let name = line.contains(":") ? String(line.split(separator: ":").last ?? "") : line
            guard !name.isEmpty else {
                skipped += 1
                continue
            }
            ignoredNames.insert(name)
        }
    }

    /// Loads every `.hdb`, `.hsb`, `.ndb` and `.ign2` file in `directory`
    /// (non-recursive, by extension). Other files are ignored; an unreadable
    /// signature file is skipped. Throws only when the directory cannot be listed.
    public mutating func load(contentsOf directory: URL, fileSystem: any FileSystem) throws {
        let children = try fileSystem.children(of: directory)
        for child in children.sorted(by: { $0.path < $1.path }) {
            let ext = child.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            guard let data = try? fileSystem.contents(of: child) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            switch ext {
            case "hdb": load(hdb: text)
            case "hsb": load(hsb: text)
            case "ndb": load(ndb: text)
            case "ign2": load(ign2: text)
            default: break
            }
        }
    }

    public static let supportedExtensions: Set<String> = ["hdb", "hsb", "ndb", "ign2"]

    /// The small offline set bundled with the module (`Resources/signatures`):
    /// EICAR hashes and patterns plus a few benign test markers.
    public static func bundledStarter() -> SignatureDatabase {
        var database = SignatureDatabase()
        if let directory = bundledSignaturesDirectory {
            try? database.load(contentsOf: directory, fileSystem: LocalFileSystem())
        }
        return database
    }

    /// Location of the bundled `signatures` directory, if the resource bundle is present.
    public static var bundledSignaturesDirectory: URL? {
        if let url = Bundle.module.url(forResource: "signatures", withExtension: nil) {
            return url
        }
        guard let resources = Bundle.module.resourceURL else { return nil }
        let url = resources.appendingPathComponent("signatures", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Querying

    public var stats: Stats {
        Stats(hashSignatures: hashCount, patternSignatures: patternList.count,
              allowlisted: ignoredNames.count, skippedLines: skipped)
    }

    /// Name of the first hash signature matching the file, or nil. Allowlisted
    /// names never match. Digests may be upper- or lower-case hex.
    public func match(md5: String, sha256: String, size: Int64) -> String? {
        if let name = firstMatch(md5Entries[md5.lowercased()], size: size) { return name }
        return firstMatch(sha256Entries[sha256.lowercased()], size: size)
    }

    /// Body patterns, minus allowlisted names.
    public var patterns: [HexPattern] {
        patternList.filter { !ignoredNames.contains($0.name) }
    }

    public func isAllowlisted(_ name: String) -> Bool {
        ignoredNames.contains(name)
    }

    // MARK: - Implementation

    private func firstMatch(_ entries: [HashEntry]?, size: Int64) -> String? {
        guard let entries else { return nil }
        for entry in entries where entry.size == nil || entry.size == size {
            if !ignoredNames.contains(entry.name) { return entry.name }
        }
        return nil
    }

    private func parseHashes(_ text: String, digestLength: Int)
        -> (entries: [(digest: String, entry: HashEntry)], skipped: Int) {
        var entries: [(digest: String, entry: HashEntry)] = []
        var skipped = 0
        for line in Self.lines(of: text) {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3,
                  let digest = Self.normalizedHex(fields[0], length: digestLength),
                  let size = Self.parseSize(fields[1]),
                  !fields[2].isEmpty else {
                skipped += 1
                continue
            }
            entries.append((digest, HashEntry(size: size, name: fields[2])))
        }
        return (entries, skipped)
    }

    /// Non-empty, trimmed lines; `#` comments are skipped silently.
    private static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func normalizedHex(_ text: String, length: Int) -> String? {
        guard text.count == length else { return nil }
        let lower = text.lowercased()
        guard lower.allSatisfy({ HexPatternParser.hexValue($0) != nil }) else { return nil }
        return lower
    }

    /// `.some(nil)` for "*", `.some(n)` for a non-negative integer, nil otherwise.
    private static func parseSize(_ text: String) -> Int64?? {
        if text == "*" { return .some(nil) }
        guard let value = Int64(text), value >= 0 else { return nil }
        return .some(value)
    }

    static func parseOffset(_ text: String) -> PatternOffset? {
        if text == "*" { return .any }
        if text.hasPrefix("EOF-") {
            guard let n = Int(text.dropFirst(4)), n >= 0 else { return nil }
            return .fromEnd(n)
        }
        guard let n = Int(text), n >= 0 else { return nil }
        return .absolute(n)
    }
}
