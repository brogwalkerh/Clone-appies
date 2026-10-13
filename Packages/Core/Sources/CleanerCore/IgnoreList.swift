import Foundation

/// User-maintained list of paths and glob patterns that scanners must skip.
///
/// - `paths`: a path is ignored when it equals an entry or lives under one
///   (component aware).
/// - `globs`: matched against the full standardized path. A pattern without a
///   `/` is additionally matched against the last path component, so `*.log`
///   ignores every `.log` file anywhere.
public struct IgnoreList: Sendable, Hashable, Codable {
    public static let empty = IgnoreList()

    public let paths: Set<URL>
    public let globs: [String]

    public init(paths: Set<URL> = [], globs: [String] = []) {
        self.paths = Set(paths.map { $0.standardizedFileURL })
        self.globs = globs
    }

    public func contains(_ url: URL) -> Bool {
        let path = PathUtil.normalizedPath(url)
        let components = PathUtil.components(ofPath: path)
        for ignored in paths {
            let ignoredComponents = PathUtil.components(ignored)
            if PathUtil.isAncestorOrEqual(prefix: ignoredComponents, path: components) {
                return true
            }
        }
        if !globs.isEmpty {
            let name = components.last ?? ""
            for glob in globs {
                let matcher = GlobMatcher(glob)
                if matcher.matches(path) { return true }
                if !glob.contains("/") && matcher.matches(name) { return true }
            }
        }
        return false
    }

    public func adding(_ url: URL) -> IgnoreList {
        var newPaths = paths
        newPaths.insert(url.standardizedFileURL)
        return IgnoreList(paths: newPaths, globs: globs)
    }

    /// Returns a copy with an additional glob pattern.
    public func adding(glob: String) -> IgnoreList {
        IgnoreList(paths: paths, globs: globs + [glob])
    }

    /// Returns a copy without `url`.
    public func removing(_ url: URL) -> IgnoreList {
        var newPaths = paths
        newPaths.remove(url.standardizedFileURL)
        return IgnoreList(paths: newPaths, globs: globs)
    }
}
