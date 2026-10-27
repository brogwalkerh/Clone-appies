import Foundation
import CleanerCore

/// Discovers installed application bundles.
///
/// Search roots are listed non-recursively: every `*.app` entry is a bundle
/// and bundles are not entered looking for more apps. `/Applications/Utilities`
/// is a root of its own. Homebrew Caskrooms use the
/// `Caskroom/<token>/<version>/<App>.app` layout and are searched three levels
/// deep. Only roots that exist are read.
public struct AppInventory: Sendable {
    /// Standard search roots, in listing order.
    public static let defaultSearchPaths: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/Applications/Setapp",
        "/System/Applications",
        "/System/Applications/Utilities",
    ]
    public static let defaultCaskrooms: [String] = [
        "/opt/homebrew/Caskroom",
        "/usr/local/Caskroom",
    ]

    private let fileSystem: any FileSystem
    private let searchPaths: [String]
    private let caskrooms: [String]

    public init(fileSystem: any FileSystem) {
        self.init(fileSystem: fileSystem, searchPaths: Self.defaultSearchPaths, caskrooms: Self.defaultCaskrooms)
    }

    /// Additional initializer with explicit roots. `~/Applications` is always
    /// added from the `home` passed to `discover`.
    public init(fileSystem: any FileSystem, searchPaths: [String], caskrooms: [String]) {
        self.fileSystem = fileSystem
        self.searchPaths = searchPaths
        self.caskrooms = caskrooms
    }

    public func discover(home: URL) async throws -> [InstalledApp] {
        var roots = searchPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        roots.insert(home.appendingPathComponent("Applications", isDirectory: true), at: min(1, roots.count))

        var candidates: [Candidate] = []
        for root in roots {
            try Task.checkCancellation()
            for child in fileSystem.readableChildren(of: root) {
                if let candidate = candidate(at: child, inCaskroom: false) {
                    candidates.append(candidate)
                }
            }
        }
        for caskroom in caskrooms.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            try Task.checkCancellation()
            for token in fileSystem.readableChildren(of: caskroom) where isDirectory(token) {
                for version in fileSystem.readableChildren(of: token) where isDirectory(version) {
                    for child in fileSystem.readableChildren(of: version) {
                        if let candidate = candidate(at: child, inCaskroom: true) {
                            candidates.append(candidate)
                        }
                    }
                }
            }
        }

        // De-duplicate by resolved bundle URL. The first non-Caskroom location
        // wins as the displayed path; a Caskroom hint from any duplicate makes
        // the app a cask.
        var order: [String] = []
        var groups: [String: [Candidate]] = [:]
        for candidate in candidates {
            let key = candidate.resolvedURL.path
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(candidate)
        }

        var apps: [InstalledApp] = []
        for key in order {
            try Task.checkCancellation()
            guard let group = groups[key] else { continue }
            let displayed = group.first { !$0.isCaskHinted } ?? group[0]
            let caskHinted = group.contains { $0.isCaskHinted }
            apps.append(await makeApp(bundleURL: displayed.bundleURL, resolvedURL: displayed.resolvedURL,
                                      caskHinted: caskHinted))
        }
        return apps.sorted {
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.bundleURL.path < $1.bundleURL.path
        }
    }

    // MARK: - Implementation

    private struct Candidate {
        let bundleURL: URL
        let resolvedURL: URL
        let isCaskHinted: Bool
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? fileSystem.attributes(of: url))?.isDirectory == true
    }

    private func candidate(at url: URL, inCaskroom: Bool) -> Candidate? {
        guard url.pathExtension.lowercased() == "app",
              let attributes = try? fileSystem.attributes(of: url) else { return nil }
        let bundleURL = url.standardizedFileURL
        if attributes.isDirectory {
            return Candidate(bundleURL: bundleURL, resolvedURL: bundleURL,
                             isCaskHinted: inCaskroom || Self.isUnderCaskroom(bundleURL))
        }
        guard attributes.isSymlink, let target = resolveSymlink(bundleURL),
              let targetAttributes = try? fileSystem.attributes(of: target),
              targetAttributes.isDirectory else { return nil }
        return Candidate(bundleURL: bundleURL, resolvedURL: target,
                         isCaskHinted: inCaskroom || Self.isUnderCaskroom(target))
    }

    /// Follows a chain of symlinks (bounded) using the file system's resolver.
    private func resolveSymlink(_ url: URL) -> URL? {
        guard let resolver = fileSystem as? any SymlinkResolving else { return nil }
        var current = url
        for _ in 0..<16 {
            guard let next = resolver.symlinkDestination(current) else { return nil }
            current = next.standardizedFileURL
            guard let attributes = try? fileSystem.attributes(of: current) else { return nil }
            if !attributes.isSymlink { return current }
        }
        return nil
    }

    static func isUnderCaskroom(_ url: URL) -> Bool {
        url.pathComponents.contains("Caskroom")
    }

    private func makeApp(bundleURL: URL, resolvedURL: URL, caskHinted: Bool) async -> InstalledApp {
        let plistURL = resolvedURL.appendingPathComponent("Contents/Info.plist")
        var plist: InfoPlist?
        if let data = try? fileSystem.contents(of: plistURL) {
            plist = try? InfoPlist(data: data)
        }
        let name = plist?.preferredName ?? bundleURL.deletingPathExtension().lastPathComponent
        let bundleID = plist?.bundleIdentifier
        let sizeWalker = FileWalker(fileSystem: fileSystem, followsSymlinks: false,
                                    skipsPackageContents: false, protectedPaths: .none)
        let size = (try? await sizeWalker.directorySize(resolvedURL)) ?? 0
        let feed = plist?.sparkleFeedURL.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let source = classify(bundleURL: bundleURL, resolvedURL: resolvedURL, bundleID: bundleID,
                              caskHinted: caskHinted, hasPlist: plist != nil)
        return InstalledApp(bundleURL: bundleURL, name: name, bundleIdentifier: bundleID,
                            version: plist?.shortVersion, build: plist?.bundleVersion, source: source,
                            sizeBytes: size, lastOpened: lastOpened(of: resolvedURL),
                            sparkleFeedURL: feed)
    }

    private func classify(bundleURL: URL, resolvedURL: URL, bundleID: String?,
                          caskHinted: Bool, hasPlist: Bool) -> AppSource {
        let system = URL(fileURLWithPath: "/System", isDirectory: true)
        if isUnder(resolvedURL, system) || isUnder(bundleURL, system) { return .system }
        if fileSystem.exists(resolvedURL.appendingPathComponent("Contents/_MASReceipt/receipt")) { return .appStore }
        if let bundleID, bundleID.lowercased().hasPrefix("com.apple.") { return .system }
        if caskHinted || Self.isUnderCaskroom(resolvedURL) { return .homebrewCask }
        let setapp = URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true)
        if isUnder(bundleURL, setapp) || isUnder(resolvedURL, setapp) { return .setapp }
        return hasPlist ? .direct : .unknown
    }

    private func isUnder(_ url: URL, _ ancestor: URL) -> Bool {
        let a = ancestor.standardizedFileURL.pathComponents
        let p = url.standardizedFileURL.pathComponents
        return p.count >= a.count && Array(p[0..<a.count]) == a
    }

    private func lastOpened(of url: URL) -> Date? {
        #if os(macOS)
        guard fileSystem is LocalFileSystem else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentAccessDateKey])
        return values?.contentAccessDate
        #else
        return nil
        #endif
    }
}
