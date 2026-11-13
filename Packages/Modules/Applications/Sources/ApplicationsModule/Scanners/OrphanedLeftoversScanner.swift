import Foundation
import CleanerCore

/// Support files under `~/Library` whose reverse-DNS name belongs to no
/// installed app. Names that do not look like bundle identifiers are skipped:
/// guessing an owner for them is too risky.
///
/// "No installed app owns this" is a guess, so:
/// - every finding is review-only (`.risky`, never pre-selected);
/// - an item is owned when it shares a vendor with any installed app (see
///   `KnownIdentifiers`), not only when the full identifier matches;
/// - LaunchAgents are never reported: `brew services` and hand-written
///   agents use reverse-DNS names that belong to no app bundle at all;
/// - the scan yields nothing when the inventory cannot be trusted: no apps
///   found, or an app whose bundle identifier could not be read (it may own
///   any of the candidates).
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
            // Fail closed: with an empty or partly unreadable inventory every
            // support file would look orphaned.
            guard Self.inventoryIsTrustworthy(apps) else { return }
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
                                                           scannerID: Self.id, risk: .risky,
                                                           detail: "No installed app appears to own this; review before removing") {
                        emitter.emit(finding)
                    }
                }
            }
        }
    }

    /// False when orphan detection has nothing sound to compare against.
    static func inventoryIsTrustworthy(_ apps: [InstalledApp]) -> Bool {
        guard !apps.isEmpty else { return false }
        return apps.allSatisfy { app in
            guard let id = app.bundleIdentifier else { return false }
            return !id.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

/// Bundle identifiers that own a leftover: installed apps, their helpers and
/// vendor-wide prefixes, `com.apple.*` and the built-in allow-list.
///
/// Matching is deliberately generous, because a miss here is a false
/// "orphan". After dropping a leading team identifier and `group.` /
/// `systemgroup.` prefixes, a candidate is owned when
/// - it equals, extends or is an ancestor of a known identifier;
/// - it shares its first two components (the vendor, `com.vendor`) with an
///   installed app;
/// - its vendor component contains, or is contained in, an installed app's
///   vendor component (`com.dropbox.*` vs `com.getdropbox.dropbox`);
/// - one of its components is an installed app's name.
struct KnownIdentifiers: Sendable {
    /// Shortest vendor / app-name token used for the fuzzy comparisons.
    static let minimumTokenLength = 4

    private let exact: [String]
    private let prefixes: [String]
    private let vendors: Set<String>
    private let vendorTokens: [String]
    private let nameTokens: Set<String>

    init(apps: [InstalledApp], allowList: [String] = OrphanedLeftoversScanner.builtInAllowList) {
        var exact = Set<String>()
        var prefixes = Set<String>()
        var vendors = Set<String>()
        var vendorTokens = Set<String>()
        var nameTokens = Set<String>()
        for app in apps {
            for name in [app.name, app.bundleStem] {
                let token = Self.token(name)
                if token.count >= Self.minimumTokenLength { nameTokens.insert(token) }
            }
            guard let id = app.bundleIdentifier, !id.isEmpty else { continue }
            let components = BundleIdentifier.ownershipComponents(id)
            exact.insert(components.joined(separator: "."))
            if components.count >= 2 {
                vendors.insert(components[0] + "." + components[1])
                if components[1].count >= Self.minimumTokenLength { vendorTokens.insert(components[1]) }
            }
        }
        self.vendors = vendors
        self.vendorTokens = Array(vendorTokens)
        self.nameTokens = nameTokens
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
        let components = BundleIdentifier.ownershipComponents(candidate)
        let id = components.joined(separator: ".")
        for known in exact where BundleIdentifier.matches(id, known: known) { return true }
        for prefix in prefixes where id == prefix || id.hasPrefix(prefix + ".") { return true }
        guard components.count >= 2 else { return false }
        if vendors.contains(components[0] + "." + components[1]) { return true }
        let vendor = components[1]
        if vendor.count >= Self.minimumTokenLength {
            for token in vendorTokens where vendor.contains(token) || token.contains(vendor) { return true }
        }
        for component in components.dropFirst() where nameTokens.contains(Self.token(component)) { return true }
        return false
    }

    /// Lower-cased letters and digits of `name` ("Dropbox Helper" -> "dropboxhelper").
    static func token(_ name: String) -> String {
        String(String.UnicodeScalarView(name.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }))
    }
}
