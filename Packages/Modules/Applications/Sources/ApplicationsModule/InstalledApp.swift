import Foundation
import CleanerCore

/// Where an application came from. Drives which uninstall and update paths
/// the UI offers (system apps are listed but cannot be uninstalled).
public enum AppSource: String, Codable, Sendable, Hashable {
    case appStore, direct, homebrewCask, setapp, system, unknown
}

/// An application bundle discovered by `AppInventory`.
public struct InstalledApp: Sendable, Hashable, Codable, Identifiable {
    public var id: URL { bundleURL }
    public let bundleURL: URL
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?            // CFBundleShortVersionString
    public let build: String?              // CFBundleVersion
    public let source: AppSource
    public let sizeBytes: Int64
    public let lastOpened: Date?
    public let sparkleFeedURL: URL?        // SUFeedURL from Info.plist

    public init(bundleURL: URL, name: String, bundleIdentifier: String?, version: String?,
                build: String?, source: AppSource, sizeBytes: Int64, lastOpened: Date?,
                sparkleFeedURL: URL?) {
        self.bundleURL = bundleURL
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.source = source
        self.sizeBytes = sizeBytes
        self.lastOpened = lastOpened
        self.sparkleFeedURL = sparkleFeedURL
    }

    /// True for apps the UI must not offer to uninstall.
    public var isSystem: Bool { source == .system }

    /// The bundle's folder name without the `.app` extension (what Finder shows
    /// when no localized name is installed).
    public var bundleStem: String { bundleURL.deletingPathExtension().lastPathComponent }
}

/// The subset of `Contents/Info.plist` the Applications module reads.
public struct InfoPlist: Sendable, Hashable, Decodable {
    public var bundleName: String?
    public var displayName: String?
    public var executable: String?
    public var bundleIdentifier: String?
    public var shortVersion: String?
    public var bundleVersion: String?
    public var sparkleFeedURL: String?
    public var isUIElement: Bool

    private enum CodingKeys: String, CodingKey {
        case bundleName = "CFBundleName"
        case displayName = "CFBundleDisplayName"
        case executable = "CFBundleExecutable"
        case bundleIdentifier = "CFBundleIdentifier"
        case shortVersion = "CFBundleShortVersionString"
        case bundleVersion = "CFBundleVersion"
        case sparkleFeedURL = "SUFeedURL"
        case isUIElement = "LSUIElement"
    }

    public init(bundleName: String? = nil, displayName: String? = nil, executable: String? = nil,
                bundleIdentifier: String? = nil, shortVersion: String? = nil,
                bundleVersion: String? = nil, sparkleFeedURL: String? = nil, isUIElement: Bool = false) {
        self.bundleName = bundleName
        self.displayName = displayName
        self.executable = executable
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.sparkleFeedURL = sparkleFeedURL
        self.isUIElement = isUIElement
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleName = Self.lenientString(c, .bundleName)
        displayName = Self.lenientString(c, .displayName)
        executable = Self.lenientString(c, .executable)
        bundleIdentifier = Self.lenientString(c, .bundleIdentifier)
        shortVersion = Self.lenientString(c, .shortVersion)
        bundleVersion = Self.lenientString(c, .bundleVersion)
        sparkleFeedURL = Self.lenientString(c, .sparkleFeedURL)
        isUIElement = Self.lenientBool(c, .isUIElement)
    }

    /// Parses plist `data` (XML or binary).
    public init(data: Data) throws {
        self = try PropertyListDecoder().decode(InfoPlist.self, from: data)
    }

    /// Display name in fallback order: CFBundleName, CFBundleDisplayName,
    /// CFBundleExecutable.
    public var preferredName: String? {
        for candidate in [bundleName, displayName, executable] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return nil
    }

    /// Values occasionally ship as numbers (e.g. `CFBundleVersion` = 42).
    private static func lenientString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    /// `LSUIElement` is a boolean in modern plists but "1"/"YES" strings or
    /// integers in old ones.
    private static func lenientBool(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            let v = s.trimmingCharacters(in: .whitespaces).lowercased()
            return v == "1" || v == "yes" || v == "true"
        }
        return false
    }
}

/// File systems that can report where a symlink points. `LocalFileSystem`
/// conforms here; test doubles can adopt it retroactively.
public protocol SymlinkResolving {
    func symlinkDestination(_ url: URL) -> URL?
}

extension LocalFileSystem: SymlinkResolving {
    public func symlinkDestination(_ url: URL) -> URL? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        if target.hasPrefix("/") {
            return URL(fileURLWithPath: target).standardizedFileURL
        }
        return url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
    }
}
