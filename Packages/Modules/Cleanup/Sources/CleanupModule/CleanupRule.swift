import Foundation
import CleanerCore

/// One entry of the rules table loaded from `Resources/cleanup-rules.json`:
/// a known cache/log location with its risk level, a human description
/// (the Smart Insights fallback) and the paths it covers.
public struct CleanupRule: Codable, Sendable, Hashable {
    public let id: String
    public let category: String
    /// Relative to the home directory, or absolute when starting with "/".
    /// Components may contain the glob characters `*`, `?` and `**`.
    public let relativePaths: [String]
    public let risk: RiskLevel
    public let description: String

    public init(id: String, category: String, relativePaths: [String], risk: RiskLevel, description: String) {
        self.id = id
        self.category = category
        self.relativePaths = relativePaths
        self.risk = risk
        self.description = description
    }
}

/// The rules table. Loaded once from the module bundle via `shared`.
public struct CleanupRules: Sendable {
    /// Category id for rules that name locations no cleanup scanner may ever
    /// yield (sync state, Apple ID caches, in-flight downloads).
    public static let protectedCategory = "cleanup.protected"

    public static let shared: CleanupRules = loadBundled()

    public let rules: [CleanupRule]

    public init(rules: [CleanupRule]) {
        self.rules = rules
    }

    /// Decodes a JSON array of `CleanupRule`.
    public init(data: Data) throws {
        self.rules = try JSONDecoder().decode([CleanupRule].self, from: data)
    }

    public func rule(id: String) -> CleanupRule? {
        rules.first { $0.id == id }
    }

    public func rules(inCategory category: String) -> [CleanupRule] {
        rules.filter { $0.category == category }
    }

    /// The most specific rule whose path equals `path` or is an ancestor of it.
    public func rule(forPath path: URL, home: URL) -> CleanupRule? {
        let components = RulePath.components(of: path)
        var best: (rule: CleanupRule, depth: Int)?
        for rule in rules {
            for relative in rule.relativePaths {
                let pattern = RulePath.components(ofRule: relative, home: home)
                guard RulePath.covers(pattern: pattern, path: components) else { continue }
                if best == nil || pattern.count > best!.depth {
                    best = (rule, pattern.count)
                }
            }
        }
        return best?.rule
    }

    /// Smart Insights fallback text for `path`, if a rule covers it.
    public func description(forPath path: URL, home: URL) -> String? {
        rule(forPath: path, home: home)?.description
    }

    /// True when the most specific rule covering `path` marks it protected.
    public func isProtected(_ path: URL, home: URL) -> Bool {
        rule(forPath: path, home: home)?.category == Self.protectedCategory
    }

    /// Expands one rule path to the existing locations it names, resolving
    /// glob components against `fileSystem`.
    public func expand(_ relativePath: String, home: URL, fileSystem: any FileSystem) -> [URL] {
        RulePath.expand(relativePath, home: home, fileSystem: fileSystem)
    }

    // MARK: - Loading

    private static func loadBundled() -> CleanupRules {
        guard let url = Bundle.module.url(forResource: "cleanup-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? CleanupRules(data: data) else {
            return CleanupRules(rules: [])
        }
        return rules
    }
}

// MARK: - Path helpers

enum RulePath {
    static func components(of url: URL) -> [String] {
        url.standardizedFileURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Absolute components for a rule path: absolute rule paths are taken as is,
    /// relative ones are anchored at `home`.
    static func components(ofRule relative: String, home: URL) -> [String] {
        let own = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if relative.hasPrefix("/") { return own }
        return components(of: home) + own
    }

    static func hasGlob(_ component: String) -> Bool {
        component.contains("*") || component.contains("?")
    }

    /// True when `pattern` equals `path` or is a component-wise ancestor of it.
    /// Glob components match a single path component; `**` matches any run.
    static func covers(pattern: [String], path: [String]) -> Bool {
        // "/" names the root itself, not everything below it.
        if pattern.isEmpty { return path.isEmpty }
        if pattern.contains("**") {
            let matcher = SimpleGlob(pattern.joined(separator: "/"))
            var prefix = ""
            for component in path {
                prefix += (prefix.isEmpty ? "" : "/") + component
                if matcher.matches(prefix) { return true }
            }
            return false
        }
        guard pattern.count <= path.count else { return false }
        for (p, c) in zip(pattern, path) {
            if hasGlob(p) {
                if !SimpleGlob(p).matches(c) { return false }
            } else if p != c {
                return false
            }
        }
        return true
    }

    static func expand(_ relative: String, home: URL, fileSystem: any FileSystem) -> [URL] {
        let pattern = components(ofRule: relative, home: home)
        var current: [URL] = [URL(fileURLWithPath: "/", isDirectory: true)]
        for component in pattern {
            var next: [URL] = []
            if hasGlob(component) {
                let matcher = SimpleGlob(component)
                for base in current {
                    guard let children = try? fileSystem.children(of: base) else { continue }
                    for child in children where matcher.matches(child.lastPathComponent) {
                        next.append(child)
                    }
                }
            } else {
                for base in current {
                    let candidate = base.appendingPathComponent(component)
                    if fileSystem.exists(candidate) { next.append(candidate) }
                }
            }
            if next.isEmpty { return [] }
            current = next
        }
        return current.map(\.standardizedFileURL)
    }
}

/// Minimal glob matcher: `*` (no `/`), `**` (anything), `?` (one char, no `/`).
struct SimpleGlob: Sendable {
    private let pattern: [Character]

    init(_ pattern: String) { self.pattern = Array(pattern) }

    func matches(_ string: String) -> Bool {
        Self.match(pattern, 0, Array(string), 0)
    }

    private static func match(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> Bool {
        if pi == p.count { return si == s.count }
        let c = p[pi]
        if c == "*" {
            let isDouble = pi + 1 < p.count && p[pi + 1] == "*"
            let next = isDouble ? pi + 2 : pi + 1
            var k = si
            while true {
                if match(p, next, s, k) { return true }
                if k >= s.count { return false }
                if !isDouble && s[k] == "/" { return false }
                k += 1
            }
        }
        guard si < s.count else { return false }
        if c == "?" { return s[si] != "/" && match(p, pi + 1, s, si + 1) }
        return s[si] == c && match(p, pi + 1, s, si + 1)
    }
}
