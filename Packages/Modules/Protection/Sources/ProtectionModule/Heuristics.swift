import Foundation
import CleanerCore

/// Platform fact: is this executable validly code-signed? nil = unknown (Linux).
public protocol CodeSignatureVerifier: Sendable {
    func isValidlySigned(_ executable: URL) async -> Bool?
}

/// Platform fact: executables of the processes currently running.
public protocol RunningProcessPathsProvider: Sendable {
    func executablePaths() async -> [URL]
}

public struct HeuristicContext: Sendable {
    public let fileSystem: any FileSystem
    public let home: URL
    public let signatureVerifier: (any CodeSignatureVerifier)?
    public let now: Date

    public init(fileSystem: any FileSystem, home: URL, signatureVerifier: (any CodeSignatureVerifier)? = nil,
                now: Date = .now) {
        self.fileSystem = fileSystem
        self.home = home.standardizedFileURL
        self.signatureVerifier = signatureVerifier
        self.now = now
    }
}

/// What a launchd property list asks launchd to run.
public struct LaunchAgentInfo: Sendable, Hashable {
    public let label: String?
    public let program: String?
    public let programArguments: [String]
    public let runAtLoad: Bool

    /// `Program` when set, else the first `ProgramArguments` entry.
    public var executable: String? {
        program ?? programArguments.first
    }

    /// Program and arguments joined with spaces, as a shell would see them.
    public var commandLine: String {
        var parts = programArguments
        if let program, parts.first != program { parts.insert(program, at: 0) }
        return parts.joined(separator: " ")
    }

    /// Every token that could be a path: program plus all arguments.
    public var tokens: [String] {
        var all = programArguments
        if let program { all.insert(program, at: 0) }
        return all
    }

    /// Parses launchd plist data (XML or binary). nil when it is not a dictionary.
    public static func parse(_ data: Data) -> LaunchAgentInfo? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any] else { return nil }
        let arguments = (dict["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        return LaunchAgentInfo(label: dict["Label"] as? String,
                               program: dict["Program"] as? String,
                               programArguments: arguments,
                               runAtLoad: (dict["RunAtLoad"] as? Bool) ?? false)
    }
}

/// Pure functions over file metadata and small reads; platform facts are injected.
public struct Heuristics: Sendable {
    public static let temporaryPrefixes = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]
    public static let shellNames: Set<String> = ["sh", "bash", "zsh", "ksh", "dash", "fish"]
    /// Extensions that should never carry executable magic bytes.
    public static let masqueradeExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "pdf", "txt", "rtf", "md",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "mp3", "m4a", "mp4", "mov", "avi", "csv", "json", "html", "log",
    ]
    static let launchDirectoryNames: Set<String> = ["LaunchAgents", "LaunchDaemons"]
    static let headLength = 4_096

    public init() {}

    // MARK: Launch agents

    /// Flags: curl piped to a shell, `osascript -e`, `base64 -d`/`--decode`,
    /// programs under /tmp, hidden path components, missing program, and an
    /// unsigned program when a verifier says so.
    public func evaluate(launchAgentPlist url: URL, context: HeuristicContext) async -> [Threat] {
        let url = url.standardizedFileURL
        guard let data = try? context.fileSystem.contents(of: url),
              let info = LaunchAgentInfo.parse(data) else { return [] }
        let size = (try? context.fileSystem.attributes(of: url))?.sizeBytes ?? Int64(data.count)
        var threats: [Threat] = []
        func flag(_ name: String, _ severity: ThreatSeverity, _ detail: String) {
            threats.append(Threat(path: url, name: name, kind: .heuristic, severity: severity,
                                  detail: detail, sizeBytes: size))
        }

        let command = info.commandLine
        let lower = command.lowercased()
        let tokens = info.tokens

        if lower.contains("curl") || lower.contains("wget") {
            let piped = command.contains("|")
            let shell = tokens.contains { token in
                let name = (token as NSString).lastPathComponent.lowercased()
                return Self.shellNames.contains(name) || name.hasSuffix(".sh")
            }
            if piped || shell {
                flag("Heuristic.LaunchAgent.RemoteScriptPipeline", .critical,
                     "Downloads and runs a remote script: \(Self.truncated(command))")
            }
        }
        if lower.contains("base64 -d") || lower.contains("base64 --decode") || lower.contains("base64 -D") {
            flag("Heuristic.LaunchAgent.Base64Payload", .critical,
                 "Decodes a base64 payload at launch: \(Self.truncated(command))")
        }
        if lower.contains("osascript -e") {
            flag("Heuristic.LaunchAgent.InlineAppleScript", .high,
                 "Runs inline AppleScript at launch: \(Self.truncated(command))")
        }
        if let temporary = tokens.first(where: Self.isTemporaryPath) {
            flag("Heuristic.LaunchAgent.TemporaryPath", .medium,
                 "Runs from a temporary directory: \(temporary)")
        }
        if let hidden = tokens.first(where: { $0.contains("/") && PathHelpers.hasHiddenComponent($0) }) {
            flag("Heuristic.LaunchAgent.HiddenPath", .medium, "Runs from a hidden path: \(hidden)")
        }
        if let executable = info.executable, executable.hasPrefix("/") {
            let program = URL(fileURLWithPath: executable)
            if !context.fileSystem.exists(program) {
                flag("Heuristic.LaunchAgent.MissingProgram", .low, "Program does not exist: \(executable)")
            } else if let verifier = context.signatureVerifier,
                      await verifier.isValidlySigned(program) == false {
                flag("Heuristic.UnsignedLaunchAgent", .high,
                     "Persistent item runs an unsigned program: \(executable)")
            }
        }
        return threats
    }

    // MARK: Executables

    /// Reads the file head itself, then applies the executable rules.
    public func evaluate(executable url: URL, attributes: FileAttributes, context: HeuristicContext) async -> [Threat] {
        let head = (try? context.fileSystem.fileHead(of: url, length: Self.headLength)) ?? Data()
        return await evaluate(executable: url, attributes: attributes, head: head, context: context)
    }

    /// Flags executables in a hidden directory under ~/Library, executable
    /// magic bytes behind a document/media extension, and `#!` scripts in
    /// LaunchAgents/LaunchDaemons. `head` is the first few KB of the file.
    public func evaluate(executable url: URL, attributes: FileAttributes, head: Data,
                         context: HeuristicContext) async -> [Threat] {
        let url = url.standardizedFileURL
        let type = DetectedFileType.detect(head: head)
        guard type.isExecutable, type != .pe || Self.hasPESignature(head) else { return [] }
        var threats: [Threat] = []
        func flag(_ name: String, _ severity: ThreatSeverity, _ detail: String) {
            threats.append(Threat(path: url, name: name, kind: .heuristic, severity: severity,
                                  detail: detail, sizeBytes: attributes.sizeBytes))
        }

        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, Self.masqueradeExtensions.contains(ext) {
            flag("Heuristic.MasqueradingExtension", .high, "\(type.displayName) disguised as .\(ext)")
        }
        let library = context.home.appendingPathComponent("Library", isDirectory: true)
        let below = PathHelpers.components(of: url, below: library)
        if !below.isEmpty, below.dropLast().contains(where: { $0.hasPrefix(".") }) {
            flag("Heuristic.HiddenExecutable", .medium, "\(type.displayName) in a hidden folder under ~/Library")
        }
        if type == .script, Self.launchDirectoryNames.contains(url.deletingLastPathComponent().lastPathComponent) {
            flag("Heuristic.ScriptInLaunchAgents", .medium, "Script stored beside launch agents")
        }
        return threats
    }

    // MARK: Helpers

    /// "MZ" alone also starts plain text (say, a CSV row for Mozambique); a
    /// PE has `e_lfanew` (offset 0x3C) pointing at "PE\0\0" within `head`.
    static func hasPESignature(_ head: Data) -> Bool {
        let bytes = [UInt8](head)
        guard bytes.count >= 0x40 else { return false }
        let offset = Int(bytes[0x3C]) | Int(bytes[0x3D]) << 8 | Int(bytes[0x3E]) << 16 | Int(bytes[0x3F]) << 24
        guard offset >= 0x40, offset <= bytes.count - 4 else { return false }
        return bytes[offset] == 0x50 && bytes[offset + 1] == 0x45 && bytes[offset + 2] == 0 && bytes[offset + 3] == 0
    }

    static func isTemporaryPath(_ token: String) -> Bool {
        temporaryPrefixes.contains { token == $0 || token.hasPrefix($0 + "/") }
    }

    private static func truncated(_ text: String, limit: Int = 120) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
