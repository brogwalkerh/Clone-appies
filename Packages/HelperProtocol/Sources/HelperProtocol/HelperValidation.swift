import Foundation

/// Why a `HelperRequest` was rejected. Both sides raise the same errors.
public enum HelperValidationError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidPath(String)
    case outsideAllowedRoot(String)
    case invalidLabel(String)
    case invalidVolume(String)
    case invalidHome(String)

    public var description: String {
        switch self {
        case .invalidPath(let path): return "Invalid path: \(path)"
        case .outsideAllowedRoot(let path): return "Path is outside the allowed roots: \(path)"
        case .invalidLabel(let label): return "Invalid launchd label: \(label)"
        case .invalidVolume(let volume): return "Invalid volume: \(volume)"
        case .invalidHome(let home): return "Invalid caller home: \(home)"
        }
    }
}

/// Pure validation of a `HelperRequest`. No I/O except the injected symlink
/// check, so the rules are unit-tested on Linux and applied identically by the
/// app (before any XPC traffic) and by the helper (before any command runs).
public struct HelperRequestValidator: Sendable {
    /// Roots under which `removeSystemCache` may operate. The path must be
    /// strictly below one of these (the root itself is rejected).
    public static let systemCacheRoots = ["/Library/Caches", "/private/var/folders"]

    /// Symlink probe backed by `FileManager` (lstat semantics: the final
    /// component is not followed). Use this on the helper side.
    public static let fileManagerSymlinkCheck: @Sendable (String) -> Bool = { path in
        guard let attributes = try? FileManager().attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }

    private let isSymlink: @Sendable (String) -> Bool

    public init(isSymlink: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.isSymlink = isSymlink
    }

    public func validate(_ request: HelperRequest) throws {
        try Self.validateHome(request.callerHome)
        switch request.operation {
        case .ping, .freePurgeableSpace, .flushDNSCache, .rebuildLaunchServices,
             .resetBluetoothModule, .speedUpMail:
            return
        case .runPeriodicScripts:
            return
        case .reindexSpotlight(let volume):
            try Self.validateVolume(volume)
        case .thinLocalSnapshots(let bytesToFree):
            guard bytesToFree > 0 else {
                throw HelperValidationError.invalidPath("bytesToFree must be > 0, got \(bytesToFree)")
            }
        case .removeSystemCache(let path):
            try validateSystemCachePath(path)
        case .setLaunchDaemonEnabled(let label, _):
            try Self.validateLabel(label)
        }
    }

    // MARK: - Rules

    static func validateHome(_ home: String) throws {
        guard Self.isStandardizedAbsolute(home) else { throw HelperValidationError.invalidHome(home) }
        if home == "/var/root" { return }
        let components = Self.components(of: home)
        guard components.count >= 2, components[0] == "Users" else {
            throw HelperValidationError.invalidHome(home)
        }
    }

    func validateSystemCachePath(_ path: String) throws {
        guard Self.isStandardizedAbsolute(path) else { throw HelperValidationError.invalidPath(path) }
        let underRoot = Self.systemCacheRoots.contains { root in
            path != root && path.hasPrefix(root + "/")
        }
        guard underRoot else { throw HelperValidationError.outsideAllowedRoot(path) }
        guard !isSymlink(path) else { throw HelperValidationError.invalidPath(path) }
    }

    static func validateVolume(_ volume: String) throws {
        if volume == "/" { return }
        guard Self.isStandardizedAbsolute(volume) else { throw HelperValidationError.invalidVolume(volume) }
        let components = Self.components(of: volume)
        guard components.count == 2, components[0] == "Volumes" else {
            throw HelperValidationError.invalidVolume(volume)
        }
    }

    static func validateLabel(_ label: String) throws {
        guard !label.isEmpty, label.unicodeScalars.allSatisfy(Self.isLabelScalar) else {
            throw HelperValidationError.invalidLabel(label)
        }
        // launchd labels are case-sensitive, but refusing any casing of the
        // Apple prefix is the safer reading of the rule.
        guard !label.lowercased().hasPrefix("com.apple.") else {
            throw HelperValidationError.invalidLabel(label)
        }
    }

    // MARK: - Path helpers (pure; no FileManager, so behaviour is identical on every platform)

    private static func isLabelScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", ".", "-": return true
        default: return false
        }
    }

    /// Splits an absolute path into its components, dropping the leading root.
    static func components(of path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map { $0 }
    }

    /// True when `path` is absolute and already in canonical form: no empty
    /// components (`//`), no `.` or `..` components, no trailing slash, no NUL.
    /// `/` alone is not considered standardized here because no rule accepts
    /// it as a target; callers that allow it check for it first.
    static func isStandardizedAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, !path.contains("\0") else { return false }
        for component in components(of: path) {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }
}
