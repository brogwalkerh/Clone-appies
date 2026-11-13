import Foundation

/// Helpers for reverse-DNS bundle identifiers.
enum BundleIdentifier {
    /// Extensions that leftover files carry on top of their bundle id.
    static let strippableExtensions: Set<String> = ["plist", "savedstate", "binarycookies"]

    /// Longest prefix of `name` matching `^[a-z0-9-]+(\.[a-z0-9-]+){2,}`
    /// (case-insensitive), or nil when `name` does not look like a bundle id.
    static func extract(from name: String) -> String? {
        var components: [String] = []
        var current = ""
        for scalar in name.unicodeScalars {
            if scalar == "." {
                if current.isEmpty { break }
                components.append(current)
                current = ""
            } else if isIdentifierScalar(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                break
            }
        }
        if !current.isEmpty { components.append(current) }
        guard components.count >= 3 else { return nil }
        return components.joined(separator: ".")
    }

    /// `extract(from:)` after dropping a leftover-file extension such as
    /// `.plist` or `.savedState`.
    static func extract(fromFileName name: String) -> String? {
        let url = URL(fileURLWithPath: name)
        if strippableExtensions.contains(url.pathExtension.lowercased()) {
            return extract(from: url.deletingPathExtension().lastPathComponent)
        }
        return extract(from: name)
    }

    /// True when `candidate` equals `known`, lives under it (`known.helper`)
    /// or is an ancestor of it (`com.vendor` for `com.vendor.app`), comparing
    /// case-insensitively on component boundaries.
    static func matches(_ candidate: String, known: String) -> Bool {
        let a = candidate.lowercased()
        let b = known.lowercased()
        if a == b { return true }
        return a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }

    /// True for a path-component-safe name: non-empty, not `.` or `..`, and
    /// free of path separators and NULs. Bundle names and identifiers come
    /// from an app's own Info.plist, i.e. from untrusted input, and are
    /// appended to `~/Library/...` paths.
    static func isSafePathComponent(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0.value == 0 }
    }

    /// An Apple developer team identifier: exactly ten upper-case letters or
    /// digits, as prefixed to app-group and keychain-group names.
    static func isTeamID(_ component: String) -> Bool {
        component.unicodeScalars.count == 10 && component.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    /// Lower-cased components of `id` with any leading team identifier and
    /// `group.` / `systemgroup.` prefixes removed
    /// (`ABCDE12345.group.com.vendor.app` -> `[com, vendor, app]`).
    static func ownershipComponents(_ id: String) -> [String] {
        var parts = id.split(separator: ".").map(String.init)
        while parts.count > 2, let first = parts.first,
              isTeamID(first) || first.lowercased() == "group" || first.lowercased() == "systemgroup" {
            parts.removeFirst()
        }
        return parts.map { $0.lowercased() }
    }

    /// Last two components of a bundle id (`vendor.app` for `com.vendor.app`).
    static func vendorSuffix(_ bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts.suffix(2).joined(separator: ".")
    }

    /// True when `name` (split on `.`) contains `needle`'s components as a
    /// contiguous run, case-insensitively.
    static func name(_ name: String, containsComponents needle: String) -> Bool {
        let haystack = name.lowercased().split(separator: ".").map(String.init)
        let target = needle.lowercased().split(separator: ".").map(String.init)
        guard !target.isEmpty, haystack.count >= target.count else { return false }
        for start in 0...(haystack.count - target.count) {
            if Array(haystack[start..<(start + target.count)]) == target { return true }
        }
        return false
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-": return true
        default: return false
        }
    }
}
