import Foundation
import Testing
import CleanerCore
import HelperProtocol
@testable import PerformanceModule

@Suite("MaintenanceCatalog")
struct MaintenanceCatalogTests {
    let tasks = MaintenanceCatalog.all

    @Test func containsEveryContractTask() {
        #expect(tasks.map(\.id) == [
            "maintenance.freeRAM", "maintenance.freePurgeable", "maintenance.runPeriodic",
            "maintenance.flushDNS", "maintenance.reindexSpotlight", "maintenance.rebuildLaunchServices",
            "maintenance.thinSnapshots", "maintenance.speedUpMail", "maintenance.resetBluetooth",
            "maintenance.clearFontCaches", "maintenance.repairUserPermissions",
        ])
    }

    @Test func idsAreUniqueAndPrefixed() {
        let ids = tasks.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("maintenance.") })
        #expect(MaintenanceCatalog.task(id: "maintenance.flushDNS")?.name == "Flush DNS Cache")
        #expect(MaintenanceCatalog.task(id: "maintenance.nope") == nil)
    }

    @Test func helperTasksHaveOperationsAndNoUserSteps() {
        for task in tasks where task.requiresHelper {
            #expect(task.helperOperation != nil, "\(task.id)")
            #expect(task.userSteps.isEmpty, "\(task.id)")
            #expect(!task.helperOperations.isEmpty, "\(task.id)")
        }
    }

    @Test func userTasksHaveStepsAndNoOperations() {
        let userTasks = tasks.filter { !$0.requiresHelper }
        #expect(userTasks.map(\.id) == ["maintenance.clearFontCaches", "maintenance.repairUserPermissions"])
        for task in userTasks {
            #expect(!task.userSteps.isEmpty, "\(task.id)")
            #expect(task.helperOperation == nil, "\(task.id)")
            #expect(task.extraHelperOperations.isEmpty, "\(task.id)")
            #expect(task.userSteps.allSatisfy { $0.executable.hasPrefix("/") }, "\(task.id)")
            #expect(!task.userSteps.contains { $0.executable.hasSuffix("/sh") || $0.executable.hasSuffix("/bash") })
        }
    }

    @Test func detailsAreRealParagraphs() {
        for task in tasks {
            #expect(!task.name.isEmpty, "\(task.id)")
            #expect(!task.summary.isEmpty, "\(task.id)")
            #expect(!task.summary.contains("\n"), "\(task.id)")
            #expect(task.detail.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80, "\(task.id)")
            #expect(task.estimatedSeconds > 0, "\(task.id)")
        }
    }

    @Test func specificOperationsAndRisks() throws {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        #expect(byID["maintenance.freeRAM"]?.helperOperation == .freePurgeableSpace)
        #expect(byID["maintenance.freeRAM"]?.risk == .safe)
        #expect(byID["maintenance.freePurgeable"]?.helperOperation == .freePurgeableSpace)
        #expect(byID["maintenance.freePurgeable"]?.risk == .safe)
        #expect(byID["maintenance.runPeriodic"]?.helperOperations == [
            .runPeriodicScripts(.daily), .runPeriodicScripts(.weekly), .runPeriodicScripts(.monthly),
        ])
        #expect(byID["maintenance.runPeriodic"]?.risk == .safe)
        #expect(byID["maintenance.flushDNS"]?.helperOperation == .flushDNSCache)
        #expect(byID["maintenance.flushDNS"]?.risk == .safe)
        #expect(byID["maintenance.reindexSpotlight"]?.helperOperation == .reindexSpotlight(volume: "/"))
        #expect(byID["maintenance.reindexSpotlight"]?.risk == .caution)
        #expect(byID["maintenance.rebuildLaunchServices"]?.helperOperation == .rebuildLaunchServices)
        #expect(byID["maintenance.rebuildLaunchServices"]?.risk == .safe)
        #expect(byID["maintenance.thinSnapshots"]?.helperOperation == .thinLocalSnapshots(bytesToFree: 10_000_000_000))
        #expect(byID["maintenance.thinSnapshots"]?.risk == .caution)
        #expect(byID["maintenance.speedUpMail"]?.helperOperation == .speedUpMail)
        #expect(byID["maintenance.speedUpMail"]?.risk == .caution)
        #expect(byID["maintenance.resetBluetooth"]?.helperOperation == .resetBluetoothModule)
        #expect(byID["maintenance.resetBluetooth"]?.risk == .caution)

        let fonts = try #require(byID["maintenance.clearFontCaches"])
        #expect(fonts.risk == .caution)
        #expect(fonts.userSteps == [
            CommandStep(executable: "/usr/bin/atsutil", arguments: ["databases", "-removeUser"]),
            CommandStep(executable: "/usr/bin/atsutil", arguments: ["server", "-shutdown"]),
            CommandStep(executable: "/usr/bin/atsutil", arguments: ["server", "-ping"]),
        ])

        let permissions = try #require(byID["maintenance.repairUserPermissions"])
        #expect(permissions.risk == .caution)
        #expect(permissions.userSteps.count == 1)
        let step = try #require(permissions.userSteps.first)
        #expect(step.executable == "/usr/sbin/diskutil")
        #expect(step.arguments == ["resetUserPermissions", "/", String(getuid())])
    }

    @Test func noTaskIsRisky() {
        #expect(tasks.allSatisfy { $0.risk != .risky })
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(tasks)
        let decoded = try JSONDecoder().decode([MaintenanceTask].self, from: data)
        #expect(decoded == tasks)
    }
}
