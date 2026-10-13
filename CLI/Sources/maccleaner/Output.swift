import Foundation

/// A line-oriented output destination. The executable binds these to
/// stdout/stderr; tests bind them to in-memory buffers so command logic can be
/// exercised without spawning a process.
protocol OutputSink: Sendable {
    func write(_ line: String)
}

/// Writes lines to standard output (unbuffered, so output interleaves
/// predictably with prompts and with stderr).
struct StandardOutputSink: OutputSink {
    func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// Writes lines to standard error (unbuffered, so progress shows up live).
struct StandardErrorSink: OutputSink {
    func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// Collects lines in memory. Thread-safe so concurrent progress reporting is fine.
final class BufferSink: OutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    init() {}

    var lines: [String] {
        lock.withLock { storage }
    }

    var text: String {
        lines.joined(separator: "\n")
    }

    func write(_ line: String) {
        lock.withLock { storage.append(line) }
    }
}

/// The pair of sinks every command writes to.
struct CommandIO: Sendable {
    let out: any OutputSink
    let err: any OutputSink

    init(out: any OutputSink, err: any OutputSink) {
        self.out = out
        self.err = err
    }

    static let standard = CommandIO(out: StandardOutputSink(), err: StandardErrorSink())
}

/// Expands a leading `~` and returns a standardized file URL.
func fileURL(fromArgument path: String, isDirectory: Bool) -> URL {
    let expanded = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expanded, isDirectory: isDirectory).standardizedFileURL
}
