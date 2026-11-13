import Foundation
import CleanerCore

public enum BackgroundItemDomain: String, Codable, Sendable, Hashable, CaseIterable {
    case userAgent, systemAgent, systemDaemon, loginItemApp

    /// Display order: user agents first, then system agents, daemons, login items.
    var sortRank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A login or background item described by a launchd plist (or a bare
/// privileged helper binary). Pure data; `enabledState` is nil when unknown.
public struct BackgroundItem: Sendable, Hashable, Codable, Identifiable {
    public var id: URL { plistURL }
    public let plistURL: URL
    public let label: String
    public let domain: BackgroundItemDomain
    public let program: String?                   // Program or ProgramArguments[0]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    /// The program is confirmed missing: a directory on its path could be
    /// listed and does not contain the next component. Never true for Apple
    /// items, programs on removable/network volumes, or when the path cannot
    /// be inspected (unmounted volume, permission-restricted directory).
    public let isBroken: Bool
    public let isApple: Bool                      // label starts with com.apple.
    public let ownerAppName: String?              // best-effort from path / label
    public let enabledState: Bool?

    public init(plistURL: URL, label: String, domain: BackgroundItemDomain, program: String?,
                runAtLoad: Bool, keepAlive: Bool, isBroken: Bool, isApple: Bool,
                ownerAppName: String?, enabledState: Bool?) {
        self.plistURL = plistURL
        self.label = label
        self.domain = domain
        self.program = program
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.isBroken = isBroken
        self.isApple = isApple
        self.ownerAppName = ownerAppName
        self.enabledState = enabledState
    }
}

/// Answers whether launchd currently has an item enabled (`launchctl
/// print-disabled` on macOS). Return nil when unknown.
public protocol LaunchdStateProvider: Sendable {
    func isEnabled(label: String, domain: BackgroundItemDomain) async -> Bool?
}

/// Discovers login & background items from launchd plists and privileged
/// helper binaries. Parsing only: nothing is loaded or unloaded.
public struct BackgroundItemsInventory: Sendable {
    public static let privilegedHelperTools = "/Library/PrivilegedHelperTools"

    private let fileSystem: any FileSystem
    private let enabledStateProvider: (any LaunchdStateProvider)?

    public init(fileSystem: any FileSystem, enabledStateProvider: (any LaunchdStateProvider)? = nil) {
        self.fileSystem = fileSystem
        self.enabledStateProvider = enabledStateProvider
    }

    /// The launchd directories scanned for `home`, with their domain.
    public static func launchdDirectories(home: URL) -> [(url: URL, domain: BackgroundItemDomain)] {
        [
            (home.appendingPathComponent("Library/LaunchAgents", isDirectory: true).standardizedFileURL, .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), .systemDaemon),
        ]
    }

    public func discover(home: URL) async throws -> [BackgroundItem] {
        let home = home.standardizedFileURL
        var items: [BackgroundItem] = []
        for directory in Self.launchdDirectories(home: home) {
            try Task.checkCancellation()
            for file in readableChildren(of: directory.url) where file.pathExtension.lowercased() == "plist" {
                guard let attributes = try? fileSystem.attributes(of: file), !attributes.isDirectory else { continue }
                guard let data = try? fileSystem.contents(of: file) else { continue }
                guard let parsed = parseItem(data, url: file, domain: directory.domain, home: home) else { continue }
                items.append(await resolveEnabledState(of: parsed))
            }
        }
        let helpersDirectory = URL(fileURLWithPath: Self.privilegedHelperTools, isDirectory: true)
        for file in readableChildren(of: helpersDirectory) {
            try Task.checkCancellation()
            guard let attributes = try? fileSystem.attributes(of: file), !attributes.isDirectory else { continue }
            let label = file.lastPathComponent
            let item = BackgroundItem(plistURL: file.standardizedFileURL, label: label, domain: .systemDaemon,
                                      program: file.standardizedFileURL.path, runAtLoad: false, keepAlive: false,
                                      isBroken: false, isApple: Self.isAppleLabel(label),
                                      ownerAppName: Self.ownerName(program: nil, label: label), enabledState: nil)
            items.append(await resolveEnabledState(of: item))
        }
        return items.sorted {
            if $0.domain != $1.domain { return $0.domain.sortRank < $1.domain.sortRank }
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.plistURL.path < $1.plistURL.path
        }
    }

    // MARK: - Parsing

    /// Parses one launchd plist; `isConfirmedMissing` answers for the
    /// (expanded) absolute program path and must return true only when the
    /// program is known to be gone, not merely unreachable. It is not asked
    /// about Apple items or programs on removable/network volumes. Returns nil
    /// when the data is not a plist dictionary.
    static func parse(plist data: Data, url: URL, domain: BackgroundItemDomain, home: URL,
                      isConfirmedMissing: (String) -> Bool) -> BackgroundItem? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any] else { return nil }
        let label = (dict["Label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = (label?.isEmpty == false) ? label! : url.deletingPathExtension().lastPathComponent

        var program: String?
        if let value = dict["Program"] as? String, !value.isEmpty {
            program = value
        } else if let arguments = dict["ProgramArguments"] as? [Any],
                  let first = arguments.first as? String, !first.isEmpty {
            program = first
        }

        let runAtLoad = boolValue(dict["RunAtLoad"]) ?? false
        let keepAlive: Bool
        if let flag = boolValue(dict["KeepAlive"]) {
            keepAlive = flag
        } else if let conditions = dict["KeepAlive"] as? [String: Any] {
            keepAlive = !conditions.isEmpty
        } else {
            keepAlive = false
        }

        // A working agent must never be reported broken (the finding is a
        // candidate for removal), so Apple items and programs on volumes that
        // may simply be unmounted are never flagged.
        var isBroken = false
        if let program, !isAppleLabel(resolvedLabel) {
            let expanded = expandHome(program, home: home)
            if expanded.hasPrefix("/"), !isOnDetachableVolume(expanded) {
                isBroken = isConfirmedMissing(expanded)
            }
        }

        return BackgroundItem(plistURL: url.standardizedFileURL, label: resolvedLabel, domain: domain,
                              program: program, runAtLoad: runAtLoad, keepAlive: keepAlive,
                              isBroken: isBroken, isApple: isAppleLabel(resolvedLabel),
                              ownerAppName: ownerName(program: program, label: resolvedLabel),
                              enabledState: nil)
    }

    static func isAppleLabel(_ label: String) -> Bool {
        label.hasPrefix("com.apple.")
    }

    /// Mount points for external and network volumes: a program there may be
    /// absent only because the volume is not mounted right now.
    static let detachableVolumeRoots = ["/Volumes", "/Network", "/net"]

    static func isOnDetachableVolume(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return detachableVolumeRoots.contains { standardized == $0 || standardized.hasPrefix($0 + "/") }
    }

    /// True only with positive evidence that `path` is gone: its deepest
    /// existing ancestor is a directory that can be listed and the listing
    /// does not contain the next path component. A path that cannot be
    /// stat'ed because a directory is unreadable, or whose entry is listed but
    /// unreachable (dangling symlink, no search permission), is not missing.
    static func isConfirmedMissing(_ path: String, fileSystem: any FileSystem) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if fileSystem.exists(url) { return false }
        var missing = url
        var ancestor = url.deletingLastPathComponent()
        while !fileSystem.exists(ancestor) {
            guard ancestor.pathComponents.count > 1 else { return false }
            missing = ancestor
            ancestor = ancestor.deletingLastPathComponent()
        }
        guard let attributes = try? fileSystem.attributes(of: ancestor), attributes.isDirectory,
              let listing = try? fileSystem.children(of: ancestor) else { return false }
        let wanted = comparableName(missing.lastPathComponent)
        return !listing.contains { comparableName($0.lastPathComponent) == wanted }
    }

    /// Case- and normalization-insensitive, like the default APFS volume.
    private static func comparableName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `~` or `~/...` expanded against `home`; anything else unchanged.
    static func expandHome(_ path: String, home: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home.path + path.dropFirst()
    }

    /// "/Applications/<Name>.app/" anywhere in the program path wins; otherwise
    /// the second-to-last label component, capitalized.
    static func ownerName(program: String?, label: String) -> String? {
        if let program, let name = appName(in: program) { return name }
        let components = label.split(separator: ".", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }
        let component = String(components[components.count - 2])
        guard let first = component.first else { return nil }
        return first.uppercased() + component.dropFirst()
    }

    private static func appName(in path: String) -> String? {
        var searchRange = path.startIndex..<path.endIndex
        while let marker = path.range(of: "/Applications/", range: searchRange) {
            let rest = path[marker.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                let component = rest[..<slash]
                if component.hasSuffix(".app"), component.count > 4 {
                    return String(component.dropLast(4))
                }
            }
            searchRange = marker.upperBound..<path.endIndex
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        default: return nil
        }
    }

    // MARK: - Helpers

    private func parseItem(_ data: Data, url: URL, domain: BackgroundItemDomain, home: URL) -> BackgroundItem? {
        Self.parse(plist: data, url: url, domain: domain, home: home) { path in
            Self.isConfirmedMissing(path, fileSystem: fileSystem)
        }
    }

    private func resolveEnabledState(of item: BackgroundItem) async -> BackgroundItem {
        guard let enabledStateProvider else { return item }
        let state = await enabledStateProvider.isEnabled(label: item.label, domain: item.domain)
        return BackgroundItem(plistURL: item.plistURL, label: item.label, domain: item.domain,
                              program: item.program, runAtLoad: item.runAtLoad, keepAlive: item.keepAlive,
                              isBroken: item.isBroken, isApple: item.isApple,
                              ownerAppName: item.ownerAppName, enabledState: state)
    }

    private func readableChildren(of url: URL) -> [URL] {
        guard fileSystem.exists(url) else { return [] }
        return (try? fileSystem.children(of: url)) ?? []
    }
}
