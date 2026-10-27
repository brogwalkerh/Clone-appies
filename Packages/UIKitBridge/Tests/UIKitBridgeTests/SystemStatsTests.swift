import XCTest
import PerformanceModule
@testable import UIKitBridge

final class SystemStatsTests: XCTestCase {
    // MARK: MemoryPressure

    func testMemoryPressureThresholds() {
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 50, totalBytes: 100), .normal)
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 15, totalBytes: 100), .normal)   // exactly 15 % is still normal
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 14, totalBytes: 100), .warn)
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 5, totalBytes: 100), .warn)      // exactly 5 % is warn, not critical
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 4, totalBytes: 100), .critical)
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 0, totalBytes: 100), .critical)
    }

    func testMemoryPressureDegenerateInputsAreNormal() {
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 0, totalBytes: 0), .normal)
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 10, totalBytes: -1), .normal)
        XCTAssertEqual(MemoryPressure.derived(availableBytes: -10, totalBytes: 100), .critical)
    }

    func testMemoryPressureScalesWithRealSizes() {
        let total: Int64 = 16_000_000_000
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 3_000_000_000, totalBytes: total), .normal)
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 1_600_000_000, totalBytes: total), .warn)
        XCTAssertEqual(MemoryPressure.derived(availableBytes: 700_000_000, totalBytes: total), .critical)
    }

    // MARK: SystemStats

    private func makeStats(cpu: Double = 12.5, battery: Double? = 80) -> SystemStats {
        SystemStats(cpuPercent: cpu,
                    memoryUsedBytes: 8_000_000_000,
                    memoryTotalBytes: 16_000_000_000,
                    memoryPressure: .normal,
                    diskUsedBytes: 400_000_000_000,
                    diskTotalBytes: 1_000_000_000_000,
                    purgeableBytes: 20_000_000_000,
                    batteryPercent: battery,
                    batteryCycleCount: battery == nil ? nil : 312,
                    batteryHealth: battery == nil ? nil : 0.91,
                    isCharging: battery == nil ? nil : true,
                    networkInBytesPerSec: 1024,
                    networkOutBytesPerSec: 512)
    }

    func testSystemStatsHashableSmoke() {
        let a = makeStats()
        let b = makeStats()
        let c = makeStats(cpu: 99)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b, c]).count, 2)
        XCTAssertTrue(a.hasBattery)
        XCTAssertFalse(makeStats(battery: nil).hasBattery)
    }

    // MARK: Delta helpers

    func testCPUPercentFromTickDeltas() {
        let before = HostStatistics.CPUTicks(busy: 100, total: 1000)
        let after = HostStatistics.CPUTicks(busy: 350, total: 1500)
        XCTAssertEqual(HostStatistics.cpuPercent(from: before, to: after), 50, accuracy: 0.0001)
        XCTAssertEqual(HostStatistics.cpuPercent(from: after, to: before), 0)   // counters went backwards
    }

    func testNetworkRateHandlesCounterWrap() {
        XCTAssertEqual(HostStatistics.wrappedDelta(from: 100, to: 300), 200)
        XCTAssertEqual(HostStatistics.wrappedDelta(from: UInt64(UInt32.max) - 9, to: 10), 20)
        var previous = HostStatistics.NetworkCounters()
        previous.interfaces["en0"] = (1000, 500)
        var current = HostStatistics.NetworkCounters()
        current.interfaces["en0"] = (3000, 1500)
        current.interfaces["en1"] = (10, 10)   // new interface: no previous counter, ignored
        let rate = HostStatistics.networkRate(from: previous, to: current, seconds: 2)
        XCTAssertEqual(rate.inPerSec, 1000, accuracy: 0.0001)
        XCTAssertEqual(rate.outPerSec, 500, accuracy: 0.0001)
    }

    // MARK: Process classification

    func testIsSystemClassification() {
        XCTAssertTrue(DarwinProcessSampler.isSystem(uid: 0, executablePath: "/usr/bin/anything"))
        XCTAssertTrue(DarwinProcessSampler.isSystem(uid: 501, executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
        XCTAssertTrue(DarwinProcessSampler.isSystem(uid: 501, executablePath: "/usr/libexec/trustd"))
        XCTAssertFalse(DarwinProcessSampler.isSystem(uid: 501, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"))
        XCTAssertFalse(DarwinProcessSampler.isSystem(uid: 501, executablePath: nil))
        XCTAssertFalse(DarwinProcessSampler.isSystem(uid: nil, executablePath: "/usr/bin/zsh"))
    }

    func testResponsivenessMapping() {
        XCTAssertEqual(DarwinProcessSampler.responsiveness(from: .success), true)
        XCTAssertEqual(DarwinProcessSampler.responsiveness(from: .cannotComplete), false)
        XCTAssertNil(DarwinProcessSampler.responsiveness(from: .apiDisabled))
        XCTAssertNil(DarwinProcessSampler.responsiveness(from: .notImplemented))
    }

    // MARK: launchctl

    func testLaunchctlServiceTargets() {
        XCTAssertEqual(LaunchctlStateProvider.serviceTarget(label: "com.example.agent", domain: .userAgent, uid: 501),
                       "gui/501/com.example.agent")
        XCTAssertEqual(LaunchctlStateProvider.serviceTarget(label: "com.example.agent", domain: .systemAgent, uid: 501),
                       "gui/501/com.example.agent")
        XCTAssertEqual(LaunchctlStateProvider.serviceTarget(label: "com.example.daemon", domain: .systemDaemon, uid: 501),
                       "system/com.example.daemon")
        XCTAssertNil(LaunchctlStateProvider.serviceTarget(label: "com.example.app", domain: .loginItemApp, uid: 501))
        XCTAssertNil(LaunchctlStateProvider.serviceTarget(label: "", domain: .userAgent, uid: 501))
        XCTAssertNil(LaunchctlStateProvider.serviceTarget(label: "bad label", domain: .userAgent, uid: 501))
        XCTAssertNil(LaunchctlStateProvider.serviceTarget(label: "../system/x", domain: .userAgent, uid: 501))
    }

    func testLaunchctlInterpretation() {
        XCTAssertEqual(LaunchctlStateProvider.interpret(exitStatus: 0, output: "com.example.agent = { ... }"), true)
        XCTAssertEqual(LaunchctlStateProvider.interpret(exitStatus: 113, output: ""), false)
        XCTAssertEqual(LaunchctlStateProvider.interpret(exitStatus: 1, output: "Could not find service \"x\" in domain for uid: 501"), false)
        XCTAssertNil(LaunchctlStateProvider.interpret(exitStatus: 1, output: "Bad request"))
        XCTAssertNil(LaunchctlStateProvider.interpret(exitStatus: 2, output: ""))
    }

    func testScreenCleaningCountdownFormat() {
        XCTAssertEqual(ScreenCleaningModel.format(seconds: 120), "02:00")
        XCTAssertEqual(ScreenCleaningModel.format(seconds: 97), "01:37")
        XCTAssertEqual(ScreenCleaningModel.format(seconds: 0), "00:00")
        XCTAssertEqual(ScreenCleaningModel.format(seconds: -5), "00:00")
    }

    // MARK: ProcessRunner

    func testProcessRunnerCapturesOutputAndStatus() async throws {
        let ok = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"])
        XCTAssertEqual(ok.exitStatus, 0)
        XCTAssertEqual(ok.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "hello")

        let failing = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                                  arguments: ["-c", "echo oops 1>&2; exit 3"],
                                                  capturesStandardError: true)
        XCTAssertEqual(failing.exitStatus, 3)
        XCTAssertEqual(failing.stderrText.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
    }
}
