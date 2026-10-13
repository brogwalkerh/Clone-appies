import Foundation
import CleanerCore

/// Support files under `~/Library` whose reverse-DNS name belongs to no
/// installed app. Names that do not look like bundle identifiers are skipped:
/// guessing an owner for them is too risky.
public struct OrphanedLeftoversScanner: CleanerScanner {
    public static let id = "applications.orphanedLeftovers"
    public let displayName = "Orphaned App Leftovers"
    public let module = ModuleID.applications

    /// Locations searched, relative to home. Preferences is limited to plists.
    static let locations: [(relative: String, plistsOnly: Bool)] = [
        ("Library/Application Support", false),
        ("Library/Caches", false),
        ("Library/Preferences", true),
        ("Library/Containers", false),
        ("Library/Saved Application State", false),
        ("Library/HTTPStorages", false),
        ("Library/WebKit", false),
        ("Library/LaunchAgents", true),
    ]

    /// Identifiers that are never reported even though no app in the
    /// inventory owns them: shared updaters, frameworks and vendor-wide dirs.
    /// A `*` suffix matches the id and everything beneath it.
    public static let builtInAllowList: [String] = [
        "com.apple.*",
        "com.google.Keystone",
        "com.google.GoogleUpdater",
        "com.microsoft.autoupdate2",
        "com.microsoft.update.agent",
        "com.microsoft.office",
        "com.microsoft.OneDriveUpdater",
        "org.sparkle-project.Sparkle",
        "com.adobe.*",
        "com.oracle.java",
        "org.openjdk.*",
        "com.docker.*",
        "com.github.*",
        "org.mozilla.*",
        "com.crashlytics.*",
        "io.sentry.*",
    ]

    private let searchPaths: [String]
    private let caskrooms: [String]

    public init() {
        self.init(searchPaths: AppInventory.defaultSearchPaths, caskrooms: AppInventory.defaultCaskrooms)
    }

    /// Additional initializer with explicit inventory roots, for tests.
    public init(searchPaths: [String], caskrooms: [String]) {
        self.searchPaths = searchPaths
        self.caskrooms = caskrooms
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let searchPaths = self.searchPaths
        let caskrooms = self.caskrooms
        return makeFindingStream { emitter in
            let inventory = AppInventory(fileSystem: context.fileSystem, searchPaths: searchPaths, caskrooms: caskrooms)
            let apps = try await inventory.discover(home: context.home)
            let known = KnownIdentifiers(apps: apps)

            for location in Self.locations {
                try Task.checkCancellation()
                let directory = context.homePath(location.relative)
                for child in context.readableChildren(of: directory) {
                    try Task.checkCancellation()
                    let name = child.lastPathComponent
                    if location.plistsOnly && child.pathExtension.lowercased() != "plist" { continue }
                    guard let identifier = BundleIdentifier.extract(fromFileName: name) else { continue }
                    if known.contains(identifier) { continue }
                    if let finding = await context.finding(at: child, category: ApplicationsCategory.orphaned,
                                                           scannerID: Self.id, risk: .safe,
                                                           detail: "Left behind by an app that is no longer installed") {
                        emitter.emit(finding)
                    }
                }
            }
        }
    }
}

/// Bundle identifiers that own a leftover: installed apps, their helpers and
/// vendor-wide prefixes, `com.apple.*` and the built-in allow-list.
struct KnownIdentifiers: Sendable {
    private let exact: [String]
    private let prefixes: [String]

    init(apps: [InstalledApp], allowList: [String] = OrphanedLeftoversScanner.builtInAllowList) {
        var exact = Set<String>()
        var prefixes = Set<String>()
        for app in apps {
            if let id = app.bundleIdentifier?.lowercased(), !id.isEmpty { exact.insert(id) }
        }
        for entry in allowList {
            let lower = entry.lowercased()
            if lower.hasSuffix(".*") {
                prefixes.insert(String(lower.dropLast(2)))
            } else if lower.hasSuffix("*") {
                prefixes.insert(String(lower.dropLast()))
            } else {
                exact.insert(lower)
            }
        }
        self.exact = Array(exact)
        self.prefixes = Array(prefixes)
    }

    func contains(_ candidate: String) -> Bool {
        var id = candidate.lowercased()
        if id.hasPrefix("group.") { id = String(id.dropFirst("group.".count)) }
        for known in exact where BundleIdentifier.matches(id, known: known) { return true }
        for prefix in prefixes where id == prefix || id.hasPrefix(prefix + ".") { return true }
        return false
    }
}
