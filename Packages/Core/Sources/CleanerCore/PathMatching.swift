import Foundation

/// Path helpers shared by `ProtectedPaths`, `IgnoreList`, `FileWalker` and
/// `ScanCoordinator`.
enum PathUtil {
    /// Standardized absolute path string without a trailing slash (except "/").
    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// Path components of the normalized path, excluding the leading "/".
    static func components(_ url: URL) -> [String] {
        components(ofPath: normalizedPath(url))
    }

    static func components(ofPath path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// True when `prefix` equals `path` or is a path-component-aware ancestor
    /// of it: "/usr" covers "/usr/lib" but not "/usrdata".
    static func isAncestorOrEqual(prefix: [String], path: [String]) -> Bool {
        guard prefix.count <= path.count else { return false }
        return Array(path[0..<prefix.count]) == prefix
    }
}

/// A small glob matcher. Supported syntax:
/// - `*`  matches any run of characters except `/`
/// - `**` matches any run of characters including `/` (zero or more components)
/// - `?`  matches exactly one character except `/`
/// Everything else matches literally.
struct GlobMatcher: Sendable, Hashable {
    let pattern: [Character]

    init(_ pattern: String) {
        self.pattern = Array(pattern)
    }

    func matches(_ string: String) -> Bool {
        let s = Array(string)
        return Self.match(pattern, 0, s, 0)
    }

    private static func match(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> Bool {
        if pi == p.count { return si == s.count }
        let c = p[pi]
        if c == "*" {
            if pi + 1 < p.count && p[pi + 1] == "*" {
                // `**`
                var next = pi + 2
                if next < p.count && p[next] == "/" {
                    // "**/" may match zero components.
                    if match(p, next + 1, s, si) { return true }
                    next += 1
                    // Otherwise consume one or more full components.
                    var k = si
                    while k < s.count {
                        if s[k] == "/" && match(p, next, s, k + 1) { return true }
                        k += 1
                    }
                    return false
                }
                var k = si
                while k <= s.count {
                    if match(p, next, s, k) { return true }
                    k += 1
                }
                return false
            }
            var k = si
            while true {
                if match(p, pi + 1, s, k) { return true }
                if k >= s.count || s[k] == "/" { return false }
                k += 1
            }
        }
        guard si < s.count else { return false }
        if c == "?" {
            return s[si] != "/" && match(p, pi + 1, s, si + 1)
        }
        return s[si] == c && match(p, pi + 1, s, si + 1)
    }
}
