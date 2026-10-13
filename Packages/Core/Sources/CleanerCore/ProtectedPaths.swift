import Foundation

/// Paths no scanner may ever return and no remover may ever touch.
///
/// Matching is path-component aware: a prefix of `/usr` protects `/usr/lib`
/// but not `/usrdata`. In addition to literal prefixes, a small set of glob
/// patterns (see `GlobMatcher`) is supported for things like Time Machine
/// backup bundles whose names are not known in advance.
public struct ProtectedPaths: Sendable, Hashable, Codable {
    /// /System, /usr, /bin, /sbin, /private/var/db, /Library/Apple, Time Machine mounts, app's own containers
    public static let `default`: ProtectedPaths = makeDefault()

    public static let none = ProtectedPaths(prefixes: [])

    private let prefixes: [String]
    private let globs: [String]

    public init(prefixes: [URL]) {
        self.init(prefixes: prefixes, globs: [])
    }

    /// Additional initializer taking glob patterns (matched against the full
    /// standardized path and every ancestor of it).
    public init(prefixes: [URL], globs: [String]) {
        var seen = Set<String>()
        var normalized: [String] = []
        for url in prefixes {
            let path = PathUtil.normalizedPath(url)
            if seen.insert(path).inserted { normalized.append(path) }
        }
        self.prefixes = normalized
        self.globs = globs
    }

    /// The protected prefixes, as file URLs.
    public var prefixURLs: [URL] {
        prefixes.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func isProtected(_ url: URL) -> Bool {
        let path = PathUtil.normalizedPath(url)
        let components = PathUtil.components(ofPath: path)
        for prefix in prefixes {
            if prefix == "/" { return true }
            let prefixComponents = PathUtil.components(ofPath: prefix)
            if PathUtil.isAncestorOrEqual(prefix: prefixComponents, path: components) {
                return true
            }
        }
        if !globs.isEmpty {
            let matchers = globs.map(GlobMatcher.init)
            // Match the path itself and each ancestor so that a pattern naming a
            // directory protects everything below it.
            var ancestor = ""
            var candidates: [String] = []
            for component in components {
                ancestor += "/" + component
                candidates.append(ancestor)
            }
            if candidates.isEmpty { candidates = ["/"] }
            for matcher in matchers {
                for candidate in candidates where matcher.matches(candidate) {
                    return true
                }
            }
        }
        return false
    }

    /// Returns a copy with `url` added as a protected prefix.
    public func adding(_ url: URL) -> ProtectedPaths {
        ProtectedPaths(prefixes: prefixURLs + [url], globs: globs)
    }

    private static func makeDefault() -> ProtectedPaths {
        var prefixes: [URL] = []
        var globs: [String] = []
        #if os(macOS)
        for path in ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple",
                     "/Volumes/.timemachine"] {
            prefixes.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        globs.append("/Volumes/*.backupbundle")
        globs.append("/Volumes/*.sparsebundle")
        // The app's own containers and bundle.
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            prefixes.append(home.appendingPathComponent("Library/Containers/\(bundleID)", isDirectory: true))
            prefixes.append(home.appendingPathComponent("Library/Group Containers/\(bundleID)", isDirectory: true))
            prefixes.append(home.appendingPathComponent("Library/Application Support/\(bundleID)", isDirectory: true))
        }
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            prefixes.append(bundleURL)
        }
        #else
        for path in ["/usr", "/bin", "/sbin", "/etc", "/boot", "/proc", "/sys"] {
            prefixes.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        #endif
        return ProtectedPaths(prefixes: prefixes, globs: globs)
    }
}
