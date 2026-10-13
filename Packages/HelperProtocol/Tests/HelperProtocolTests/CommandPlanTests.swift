import Foundation
import Testing
@testable import HelperProtocol

@Suite("HelperCommandPlan")
struct CommandPlanTests {
    @Test func samplesCoverEveryCase() {
        let indices = Set(HelperOperation.allSamples.map(HelperOperation.caseIndex(of:)))
        #expect(indices.count == HelperOperation.caseCount)
        #expect(Set(HelperOperation.allSamples.map(\.name)).count == HelperOperation.caseCount)
    }

    @Test func everyOperationHasAPlan() {
        for operation in HelperOperation.allSamples {
            let plan = HelperCommandPlan.plan(for: operation, callerHome: validHome)
            if case .ping = operation {
                #expect(plan.steps.isEmpty)
            } else {
                #expect(!plan.steps.isEmpty, "\(operation.name) has no steps")
            }
        }
    }

    @Test func everyStepUsesAnAllowListedAbsoluteExecutable() {
        for operation in HelperOperation.allSamples {
            for step in HelperCommandPlan.plan(for: operation, callerHome: validHome).steps {
                #expect(step.executable.hasPrefix("/"), "\(operation.name): \(step.executable)")
                #expect(HelperCommandPlan.allowedExecutables.contains(step.executable), "\(operation.name): \(step.executable)")
                #expect(!step.executable.contains(".."))
            }
        }
        for executable in HelperCommandPlan.allowedExecutables {
            #expect(executable.hasPrefix("/"))
            #expect(!executable.hasSuffix("/sh"), "no shell may be allow-listed")
            #expect(!executable.hasSuffix("/bash"))
            #expect(!executable.hasSuffix("/zsh"))
        }
    }

    @Test func noStepInvokesAShellOrEmbedsCallerStringsOutsideArgv() {
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env", "/usr/bin/osascript"]
        for operation in HelperOperation.allSamples {
            for step in HelperCommandPlan.plan(for: operation, callerHome: validHome).steps {
                #expect(!shells.contains(step.executable))
                #expect(!step.arguments.contains("-c"))
            }
        }
    }

    @Test func planFromRequestMatchesPlanFromOperation() {
        let req = request(.speedUpMail)
        #expect(HelperCommandPlan.plan(for: req) == HelperCommandPlan.plan(for: req.operation, callerHome: req.callerHome))
    }

    @Test func freePurgeableSpace() {
        let steps = HelperCommandPlan.plan(for: .freePurgeableSpace, callerHome: validHome).steps
        #expect(steps == [
            CommandStep(executable: "/usr/bin/tmutil", arguments: ["thinlocalsnapshots", "/", "9999999999", "4"]),
            CommandStep(executable: "/usr/sbin/purge", arguments: []),
        ])
    }

    @Test func flushDNSCache() {
        let steps = HelperCommandPlan.plan(for: .flushDNSCache, callerHome: validHome).steps
        #expect(steps == [
            CommandStep(executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"]),
            CommandStep(executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"]),
        ])
    }

    @Test(arguments: PeriodicInterval.allCases)
    func runPeriodicScripts(interval: PeriodicInterval) {
        let steps = HelperCommandPlan.plan(for: .runPeriodicScripts(interval), callerHome: validHome).steps
        #expect(steps == [CommandStep(executable: "/usr/sbin/periodic", arguments: [interval.rawValue])])
    }

    @Test func reindexSpotlightPassesVolumeAsSingleArgument() {
        let steps = HelperCommandPlan.plan(for: .reindexSpotlight(volume: "/Volumes/My Disk"), callerHome: validHome).steps
        #expect(steps == [CommandStep(executable: "/usr/bin/mdutil", arguments: ["-E", "/Volumes/My Disk"])])
    }

    @Test func rebuildLaunchServices() {
        let steps = HelperCommandPlan.plan(for: .rebuildLaunchServices, callerHome: validHome).steps
        #expect(steps.count == 1)
        #expect(steps.first?.executable == HelperCommandPlan.Executable.lsregister)
        #expect(steps.first?.arguments == ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
    }

    @Test func thinLocalSnapshotsFormatsBytesExactly() {
        let steps = HelperCommandPlan.plan(for: .thinLocalSnapshots(bytesToFree: 5_000_000_000), callerHome: validHome).steps
        #expect(steps == [CommandStep(executable: "/usr/bin/tmutil", arguments: ["thinlocalsnapshots", "/", "5000000000", "4"])])
    }

    @Test func removeSystemCacheUsesEndOfOptionsMarker() {
        let path = "/Library/Caches/-rf weird name"
        let steps = HelperCommandPlan.plan(for: .removeSystemCache(path: path), callerHome: validHome).steps
        #expect(steps == [CommandStep(executable: "/bin/rm", arguments: ["-rf", "--", path])])
    }

    @Test func setLaunchDaemonEnabledTargetsSystemDomain() {
        let on = HelperCommandPlan.plan(for: .setLaunchDaemonEnabled(label: "com.example.d", enabled: true), callerHome: validHome).steps
        let off = HelperCommandPlan.plan(for: .setLaunchDaemonEnabled(label: "com.example.d", enabled: false), callerHome: validHome).steps
        #expect(on == [CommandStep(executable: "/bin/launchctl", arguments: ["enable", "system/com.example.d"])])
        #expect(off == [CommandStep(executable: "/bin/launchctl", arguments: ["disable", "system/com.example.d"])])
    }

    @Test func resetBluetoothModule() {
        let steps = HelperCommandPlan.plan(for: .resetBluetoothModule, callerHome: validHome).steps
        #expect(steps == [CommandStep(executable: "/usr/bin/killall", arguments: ["bluetoothd"])])
    }

    @Test func speedUpMailEmitsOneSkippableStepPerMailVersion() {
        let steps = HelperCommandPlan.plan(for: .speedUpMail, callerHome: "/Users/bob").steps
        #expect(steps.count == HelperCommandPlan.mailDataVersions.count)
        for (version, step) in zip(HelperCommandPlan.mailDataVersions, steps) {
            let index = "/Users/bob/Library/Mail/V\(version)/MailData/Envelope Index"
            #expect(step.executable == "/usr/bin/sqlite3")
            #expect(step.arguments == [index, "VACUUM;"])
            #expect(step.skipIfMissing == index)
        }
        #expect(HelperCommandPlan.mailDataVersions == 8...12)
    }

    @Test func onlySpeedUpMailDependsOnCallerHome() {
        for operation in HelperOperation.allSamples {
            let a = HelperCommandPlan.plan(for: operation, callerHome: "/Users/a")
            let b = HelperCommandPlan.plan(for: operation, callerHome: "/Users/b")
            if case .speedUpMail = operation {
                #expect(a != b)
            } else {
                #expect(a == b, "\(operation.name)")
                #expect(a.steps.allSatisfy { $0.skipIfMissing == nil })
            }
        }
    }
}
