import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ProtectionModule

/// Fixed "now" so age-based tests are deterministic.
let testNow = Date(timeIntervalSince1970: 1_760_000_000)

/// The standard, harmless EICAR anti-malware test string (68 bytes).
let eicar = #"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"#
let eicarMD5 = "44d88612fea8a8f36de82e1278abb02f"
let eicarSHA256 = "275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f"

func hex(_ text: String) -> String {
    text.utf8.map { String(format: "%02x", $0) }.joined()
}

func collect(_ scanner: any CleanerScanner, _ context: ScanContext) async throws -> [Finding] {
    var findings: [Finding] = []
    for try await finding in scanner.scan(context) { findings.append(finding) }
    return findings
}

func collectThreats(_ scanner: MalwareScanner, _ context: ScanContext) async throws -> [Threat] {
    var threats: [Threat] = []
    for try await threat in scanner.scanThreats(context) { threats.append(threat) }
    return threats
}

func context(_ fs: MockFileSystem, ignore: IgnoreList = .empty,
             protected: ProtectedPaths = .none, now: Date = testNow) -> ScanContext {
    ScanContext(fileSystem: fs, ignoreList: ignore, protectedPaths: protected, now: now)
}

/// A launchd property list as XML.
func launchdPlist(label: String = "com.example.test", program: String? = nil, arguments: [String] = []) -> String {
    var items = ""
    if let program { items += "<key>Program</key><string>\(program)</string>" }
    if !arguments.isEmpty {
        items += "<key>ProgramArguments</key><array>" + arguments.map { "<string>\($0)</string>" }.joined() + "</array>"
    }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>Label</key><string>\(label)</string>\(items)<key>RunAtLoad</key><true/></dict></plist>
    """
}

struct StubVerifier: CodeSignatureVerifier {
    let result: Bool?
    func isValidlySigned(_ executable: URL) async -> Bool? { result }
}

struct StubProcesses: RunningProcessPathsProvider {
    let paths: [URL]
    func executablePaths() async -> [URL] { paths }
}

/// Deterministic pseudo-random bytes (xorshift64).
func pseudoRandomData(count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Data {
    var x = seed
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        x ^= x &<< 13
        x ^= x &>> 7
        x ^= x &<< 17
        bytes[i] = UInt8(truncatingIfNeeded: x)
    }
    return Data(bytes)
}

extension Array where Element == Threat {
    func named(_ name: String) -> [Threat] { filter { $0.name == name } }
    func at(_ url: URL) -> [Threat] { filter { $0.path.standardizedFileURL.path == url.standardizedFileURL.path } }
    var names: Set<String> { Set(map(\.name)) }
}

extension Array where Element == Finding {
    var paths: Set<String> { Set(map { $0.path.standardizedFileURL.path }) }
    var names: Set<String> { Set(map { $0.path.lastPathComponent }) }
}

/// Builds a database from inline text.
func database(hdb: String = "", hsb: String = "", ndb: String = "", ign2: String = "") -> SignatureDatabase {
    var db = SignatureDatabase()
    if !hdb.isEmpty { db.load(hdb: hdb) }
    if !hsb.isEmpty { db.load(hsb: hsb) }
    if !ndb.isEmpty { db.load(ndb: ndb) }
    if !ign2.isEmpty { db.load(ign2: ign2) }
    return db
}
