import Foundation
import CleanerCore
import HelperProtocol

/// One entry of the Performance › Maintenance list.
///
/// A task is either *privileged* (`requiresHelper == true`, executed by the
/// root helper as one or more `HelperOperation`s) or *user-level*
/// (`userSteps` run as the current user through a `CommandRunner`).
public struct MaintenanceTask: Sendable, Hashable, Codable, Identifiable {
    public let id: String                 // "maintenance.freeRAM"
    public let name: String
    public let summary: String            // one line
    public let detail: String             // Smart Insights style explanation
    public let requiresHelper: Bool
    public let helperOperation: HelperOperation?
    public let risk: RiskLevel
    public let estimatedSeconds: Int
    /// Further helper operations run after `helperOperation`, in order
    /// (e.g. the weekly and monthly periodic scripts).
    public let extraHelperOperations: [HelperOperation]
    /// Commands run as the current user, in order, for user-level tasks.
    public let userSteps: [CommandStep]

    public init(id: String, name: String, summary: String, detail: String,
                requiresHelper: Bool, helperOperation: HelperOperation?, risk: RiskLevel,
                estimatedSeconds: Int, extraHelperOperations: [HelperOperation] = [],
                userSteps: [CommandStep] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.detail = detail
        self.requiresHelper = requiresHelper
        self.helperOperation = helperOperation
        self.risk = risk
        self.estimatedSeconds = estimatedSeconds
        self.extraHelperOperations = extraHelperOperations
        self.userSteps = userSteps
    }

    /// Every helper operation the task performs, in execution order.
    public var helperOperations: [HelperOperation] {
        guard let helperOperation else { return [] }
        return [helperOperation] + extraHelperOperations
    }
}

public enum MaintenanceCatalog {
    public static let all: [MaintenanceTask] = [
        MaintenanceTask(
            id: "maintenance.freeRAM",
            name: "Free Up RAM",
            summary: "Release inactive memory held by the file cache.",
            detail: """
            Purges the kernel's disk cache and other inactive memory so that the memory \
            shown as "used" drops back to what running apps actually need. macOS manages \
            memory well on its own, so this is mostly useful right before launching a \
            memory-hungry app such as a virtual machine, a large game or a video editor, \
            or when the system has become sluggish after heavy file copying. The purge \
            needs root, so it runs through the privileged helper.
            """,
            requiresHelper: true, helperOperation: .freePurgeableSpace, risk: .safe,
            estimatedSeconds: 15),
        MaintenanceTask(
            id: "maintenance.freePurgeable",
            name: "Free Up Purgeable Space",
            summary: "Reclaim disk space the system has marked as purgeable.",
            detail: """
            APFS keeps local Time Machine snapshots, caches and other reclaimable data \
            around as "purgeable" space: it counts as free in theory but can block large \
            downloads, installers and virtual machine images that need contiguous room. \
            This task asks the system to thin local snapshots and drop purgeable content \
            now rather than waiting for the disk to fill up. Run it when Finder reports \
            plenty of purgeable space but an install still fails for lack of disk.
            """,
            requiresHelper: true, helperOperation: .freePurgeableSpace, risk: .safe,
            estimatedSeconds: 30),
        MaintenanceTask(
            id: "maintenance.runPeriodic",
            name: "Run Maintenance Scripts",
            summary: "Run the daily, weekly and monthly system maintenance scripts.",
            detail: """
            macOS ships daily, weekly and monthly housekeeping scripts that rotate and \
            compress logs, clean temporary directories and rebuild system databases. \
            launchd normally runs them overnight, but a Mac that sleeps or shuts down \
            every night can go weeks without them, letting logs grow and temporary files \
            pile up. This task runs all three on demand. It is safe at any time; expect \
            a minute or two of disk activity while the logs are compressed.
            """,
            requiresHelper: true, helperOperation: .runPeriodicScripts(.daily), risk: .safe,
            estimatedSeconds: 120,
            extraHelperOperations: [.runPeriodicScripts(.weekly), .runPeriodicScripts(.monthly)]),
        MaintenanceTask(
            id: "maintenance.flushDNS",
            name: "Flush DNS Cache",
            summary: "Clear cached DNS lookups and restart the resolver.",
            detail: """
            The system caches the results of DNS lookups so repeated visits to a site \
            resolve instantly. When a site moves to a new server, a VPN changes your \
            resolver, or a local hosts-file edit does not take effect, stale entries can \
            keep pointing at the old address and produce "server not found" errors. \
            Flushing the cache and signalling mDNSResponder forces fresh lookups. It is \
            harmless: the first visit to each site afterwards is a few milliseconds slower.
            """,
            requiresHelper: true, helperOperation: .flushDNSCache, risk: .safe,
            estimatedSeconds: 2),
        MaintenanceTask(
            id: "maintenance.reindexSpotlight",
            name: "Reindex Spotlight",
            summary: "Erase and rebuild the Spotlight index of the startup disk.",
            detail: """
            Spotlight keeps a metadata index of every file so search, Finder tags and \
            Mail search answer instantly. If the index is damaged, searches miss files \
            that clearly exist, return deleted items, or the mds_stores process pins the \
            CPU for hours. Reindexing deletes the index and lets Spotlight rebuild it from \
            scratch. Use it only for those symptoms: the rebuild takes anywhere from \
            twenty minutes to several hours depending on disk size, and search results \
            are incomplete and the fans may run until it finishes.
            """,
            requiresHelper: true, helperOperation: .reindexSpotlight(volume: "/"), risk: .caution,
            estimatedSeconds: 10),
        MaintenanceTask(
            id: "maintenance.rebuildLaunchServices",
            name: "Rebuild Launch Services",
            summary: "Rebuild the database that maps file types to apps.",
            detail: """
            Launch Services records which app opens which file type, which apps appear \
            in the Open With menu, and where each app lives on disk. After installing, \
            moving or deleting many apps the database accumulates duplicates and stale \
            entries, which show up as the same app listed several times in Open With, \
            the wrong app launching for a document, or icons that will not update. \
            Rebuilding clears the database and re-registers the apps in the standard \
            folders. Custom Open With choices may need to be set again afterwards.
            """,
            requiresHelper: true, helperOperation: .rebuildLaunchServices, risk: .safe,
            estimatedSeconds: 60),
        MaintenanceTask(
            id: "maintenance.thinSnapshots",
            name: "Thin Time Machine Snapshots",
            summary: "Remove local Time Machine snapshots to free about 10 GB.",
            detail: """
            When the Time Machine disk is not connected, macOS stores hourly snapshots \
            on the startup disk and only deletes them when space runs low. They are what \
            makes the purgeable number in Finder so large and they can prevent a disk \
            from actually shrinking after you delete files. This task asks the system to \
            thin the oldest local snapshots until roughly 10 GB is recovered. Snapshots \
            already copied to your backup disk lose nothing; snapshots taken since the \
            last backup are the only versions that disappear.
            """,
            requiresHelper: true, helperOperation: .thinLocalSnapshots(bytesToFree: 10_000_000_000),
            risk: .caution, estimatedSeconds: 60),
        MaintenanceTask(
            id: "maintenance.speedUpMail",
            name: "Speed Up Mail",
            summary: "Compact the Mail envelope index database.",
            detail: """
            Mail keeps every message header, thread relationship and search token in an \
            SQLite database called the Envelope Index. After years of receiving and \
            deleting mail the file is full of unused pages, so opening mailboxes, \
            scrolling and searching get noticeably slower. This task vacuums the database, \
            rewriting it compactly, which often shrinks it by half and makes Mail feel \
            responsive again. Quit Mail before running it; the vacuum can take a minute \
            or two on large mailboxes and Mail may rebuild some caches on next launch.
            """,
            requiresHelper: true, helperOperation: .speedUpMail, risk: .caution,
            estimatedSeconds: 60),
        MaintenanceTask(
            id: "maintenance.resetBluetooth",
            name: "Reset Bluetooth Module",
            summary: "Restart the Bluetooth daemon to recover stuck devices.",
            detail: """
            The Bluetooth stack can get into a state where a keyboard, mouse, AirPods or \
            a car system refuse to pair or reconnect, audio stutters, or the menu bar \
            icon shows "Not Available". Restarting the bluetoothd daemon reloads the \
            controller without a reboot; launchd starts it again within a second. All \
            Bluetooth devices disconnect briefly and reconnect on their own, so expect a \
            wireless keyboard or mouse to be unresponsive for a few seconds.
            """,
            requiresHelper: true, helperOperation: .resetBluetoothModule, risk: .caution,
            estimatedSeconds: 5),
        MaintenanceTask(
            id: "maintenance.clearFontCaches",
            name: "Clear Font Caches",
            summary: "Remove the user font cache databases and restart the font server.",
            detail: """
            macOS caches rendered font data and the list of installed fonts per user. \
            When a cache goes stale, text can appear as boxes or in the wrong typeface, \
            newly installed fonts fail to show up in apps, or Font Book and apps hang \
            while loading the font menu. This task removes the user-level font cache \
            databases and restarts the font server so the caches are rebuilt from the \
            fonts on disk. Apps that are open may need to be relaunched to pick up the \
            rebuilt caches.
            """,
            requiresHelper: false, helperOperation: nil, risk: .caution,
            estimatedSeconds: 10,
            userSteps: [
                CommandStep(executable: "/usr/bin/atsutil", arguments: ["databases", "-removeUser"]),
                CommandStep(executable: "/usr/bin/atsutil", arguments: ["server", "-shutdown"]),
                CommandStep(executable: "/usr/bin/atsutil", arguments: ["server", "-ping"]),
            ]),
        MaintenanceTask(
            id: "maintenance.repairUserPermissions",
            name: "Repair User Permissions",
            summary: "Reset ownership and permissions in your home folder.",
            detail: """
            Files restored from a backup, copied from another Mac or created by a tool \
            run as root can end up owned by the wrong user or without the permissions the \
            system expects. The symptoms are apps that cannot save preferences, a Desktop \
            or Documents folder that refuses new files, or iCloud Drive that stops \
            syncing. This task runs diskutil's user permission reset on the startup disk \
            for your account, which restores the standard ownership and ACLs of your home \
            folder. It does not touch files outside your home folder.
            """,
            requiresHelper: false, helperOperation: nil, risk: .caution,
            estimatedSeconds: 120,
            userSteps: [
                CommandStep(executable: "/usr/sbin/diskutil",
                            arguments: ["resetUserPermissions", "/", String(getuid())]),
            ]),
    ]

    /// The task with the given identifier, if any.
    public static func task(id: String) -> MaintenanceTask? {
        all.first { $0.id == id }
    }
}
