import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
import HelperProtocol
@testable import PerformanceModule

let testHome = URL(fileURLWithPath: "/Users/test", isDirectory: true)

/// Drains a scanner's stream.
func collect(_ scanner: any CleanerScanner, _ context: ScanContext) async throws -> [Finding] {
    var findings: [Finding] = []
    for try await finding in scanner.scan(context) { findings.append(finding) }
    return findings
}

func context(_ fs: MockFileSystem, ignore: IgnoreList = .empty,
             protected: ProtectedPaths = .none) -> ScanContext {
    ScanContext(fileSystem: fs, ignoreList: ignore, protectedPaths: protected)
}

/// Thread-safe ordered log of events, shared by fakes.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }
    var all: [String] { lock.withLock { entries } }
}

/// Records every step and answers from a table of canned results.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    typealias Result = (exitCode: Int32, stdout: String, stderr: String)

    private let lock = NSLock()
    private var results: [CommandStep: Result] = [:]
    private var recorded: [CommandStep] = []
    var error: (any Error)?
    let log: EventLog?
    let delayNanoseconds: UInt64

    init(log: EventLog? = nil, delayNanoseconds: UInt64 = 0) {
        self.log = log
        self.delayNanoseconds = delayNanoseconds
    }

    func set(_ step: CommandStep, exitCode: Int32, stdout: String = "", stderr: String = "") {
        lock.withLock { results[step] = (exitCode, stdout, stderr) }
    }

    var steps: [CommandStep] { lock.withLock { recorded } }

    func run(_ step: CommandStep) async throws -> Result {
        lock.withLock { recorded.append(step) }
        if let error { throw error }
        log?.append("start \(step.executable) \(step.arguments.joined(separator: " "))")
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        log?.append("end \(step.executable) \(step.arguments.joined(separator: " "))")
        return lock.withLock { results[step] } ?? (0, "", "")
    }
}

/// Records every operation and answers from a table of canned responses.
final class FakeHelper: HelperPerformer, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HelperOperation: HelperResponse] = [:]
    private var recorded: [HelperOperation] = []
    var error: (any Error)?
    let log: EventLog?
    let delayNanoseconds: UInt64

    init(log: EventLog? = nil, delayNanoseconds: UInt64 = 0) {
        self.log = log
        self.delayNanoseconds = delayNanoseconds
    }

    func set(_ operation: HelperOperation, succeeded: Bool = true, message: String = "ok",
             bytesReclaimed: Int64? = nil) {
        lock.withLock {
            responses[operation] = HelperResponse(requestID: UUID(), succeeded: succeeded, message: message,
                                                  bytesReclaimed: bytesReclaimed, durationSeconds: 0.01)
        }
    }

    var operations: [HelperOperation] { lock.withLock { recorded } }

    func perform(_ operation: HelperOperation) async throws -> HelperResponse {
        lock.withLock { recorded.append(operation) }
        if let error { throw error }
        log?.append("start \(operation.name)")
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        log?.append("end \(operation.name)")
        return lock.withLock { responses[operation] }
            ?? HelperResponse(requestID: UUID(), succeeded: true, message: "ok", bytesReclaimed: nil, durationSeconds: 0)
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
}

extension HelperOperation {
    var name: String {
        switch self {
        case .runPeriodicScripts(let interval): return "periodic.\(interval.rawValue)"
        case .reindexSpotlight(let volume): return "reindex.\(volume)"
        case .thinLocalSnapshots(let bytes): return "thin.\(bytes)"
        default: return "\(self)"
        }
    }
}

/// Answers from a table keyed by label.
struct TableStateProvider: LaunchdStateProvider {
    let states: [String: Bool]
    let log: EventLog?

    init(_ states: [String: Bool], log: EventLog? = nil) {
        self.states = states
        self.log = log
    }

    func isEnabled(label: String, domain: BackgroundItemDomain) async -> Bool? {
        log?.append("\(domain.rawValue):\(label)")
        return states[label]
    }
}

// MARK: - launchd plist fixtures

/// XML launchd plist contents. `extra` is raw plist XML inserted into the dict.
func launchdPlist(label: String? = nil, program: String? = nil, programArguments: [String]? = nil,
                  runAtLoad: Bool? = nil, keepAlive: Bool? = nil, extra: String = "") -> MockFileSystem.Node {
    .data(launchdPlistData(label: label, program: program, programArguments: programArguments,
                           runAtLoad: runAtLoad, keepAlive: keepAlive, extra: extra))
}

func launchdPlistData(label: String? = nil, program: String? = nil, programArguments: [String]? = nil,
                      runAtLoad: Bool? = nil, keepAlive: Bool? = nil, extra: String = "") -> Data {
    var entries = ""
    if let label { entries += "    <key>Label</key>\n    <string>\(label)</string>\n" }
    if let program { entries += "    <key>Program</key>\n    <string>\(program)</string>\n" }
    if let programArguments {
        entries += "    <key>ProgramArguments</key>\n    <array>\n"
        for argument in programArguments { entries += "        <string>\(argument)</string>\n" }
        entries += "    </array>\n"
    }
    if let runAtLoad { entries += "    <key>RunAtLoad</key>\n    <\(runAtLoad)/>\n" }
    if let keepAlive { entries += "    <key>KeepAlive</key>\n    <\(keepAlive)/>\n" }
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \(entries)\(extra)
    </dict>
    </plist>
    """
    return Data(xml.utf8)
}

func sample(_ pid: Int32, _ name: String, cpu: Double = 0, memory: Int64 = 0,
            responsive: Bool? = nil, system: Bool = false) -> ProcessSample {
    ProcessSample(id: pid, name: name, cpuPercent: cpu, residentBytes: memory,
                  isResponsive: responsive, isSystem: system)
}

extension Array where Element == BackgroundItem {
    func labeled(_ label: String) -> BackgroundItem? { first { $0.label == label } }
    var labels: [String] { map(\.label) }
}

extension Array where Element == Finding {
    var paths: Set<String> { Set(map { $0.path.standardizedFileURL.path }) }
}
