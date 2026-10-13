import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ApplicationsModule
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fixed "now" so age-based tests are deterministic.
let testNow = Date(timeIntervalSince1970: 1_760_000_000)

func daysAgo(_ days: Double) -> Date {
    testNow.addingTimeInterval(-days * 86_400)
}

let testHome = URL(fileURLWithPath: "/Users/test", isDirectory: true)

/// Lets `AppInventory` follow `.symlink(to:)` nodes in a mock tree.
extension MockFileSystem: SymlinkResolving {}

/// Drains a scanner's stream.
func collect(_ scanner: any CleanerScanner, _ context: ScanContext) async throws -> [Finding] {
    var findings: [Finding] = []
    for try await finding in scanner.scan(context) { findings.append(finding) }
    return findings
}

func context(_ fs: MockFileSystem, ignore: IgnoreList = .empty,
             protected: ProtectedPaths = .none, now: Date = testNow) -> ScanContext {
    ScanContext(fileSystem: fs, ignoreList: ignore, protectedPaths: protected, now: now)
}

/// XML Info.plist contents.
func infoPlist(name: String? = nil, displayName: String? = nil, executable: String? = nil,
               id: String? = nil, version: String? = nil, build: String? = nil,
               feed: String? = nil, extra: String = "") -> MockFileSystem.Node {
    .data(infoPlistData(name: name, displayName: displayName, executable: executable, id: id,
                        version: version, build: build, feed: feed, extra: extra))
}

func infoPlistData(name: String? = nil, displayName: String? = nil, executable: String? = nil,
                   id: String? = nil, version: String? = nil, build: String? = nil,
                   feed: String? = nil, extra: String = "") -> Data {
    var entries = ""
    func add(_ key: String, _ value: String?) {
        guard let value else { return }
        entries += "    <key>\(key)</key>\n    <string>\(value)</string>\n"
    }
    add("CFBundleName", name)
    add("CFBundleDisplayName", displayName)
    add("CFBundleExecutable", executable)
    add("CFBundleIdentifier", id)
    add("CFBundleShortVersionString", version)
    add("CFBundleVersion", build)
    add("SUFeedURL", feed)
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

func makeApp(name: String, id: String?, version: String? = "1.0", build: String? = "100",
             path: String? = nil, source: AppSource = .direct, feed: String? = nil) -> InstalledApp {
    InstalledApp(bundleURL: URL(fileURLWithPath: path ?? "/Applications/\(name).app", isDirectory: true),
                 name: name, bundleIdentifier: id, version: version, build: build, source: source,
                 sizeBytes: 1_000, lastOpened: nil, sparkleFeedURL: feed.flatMap { URL(string: $0) })
}

extension Array where Element == Finding {
    func named(_ lastComponent: String) -> Finding? {
        first { $0.path.lastPathComponent == lastComponent }
    }
    func at(_ path: String) -> Finding? {
        first { $0.path.standardizedFileURL.path == path }
    }
    var paths: Set<String> { Set(map { $0.path.standardizedFileURL.path }) }
    var totalBytes: Int64 { reduce(0) { $0 + $1.sizeBytes } }
}

extension Array where Element == InstalledApp {
    func named(_ name: String) -> InstalledApp? { first { $0.name == name } }
    var names: [String] { map(\.name) }
}

// MARK: - Canned HTTP responses

/// What the stub protocol answers for a URL.
enum StubResponse: Sendable {
    case data(Data, status: Int = 200)
    case failure
}

/// Serves canned responses from `StubURLProtocol.responses`; register it on an
/// ephemeral configuration.
final class StubURLProtocol: URLProtocol {
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String: StubResponse] = [:]
        private var requested: [String] = []

        func set(_ url: String, _ response: StubResponse) {
            lock.lock(); defer { lock.unlock() }
            responses[url] = response
        }
        func response(for url: String) -> StubResponse? {
            lock.lock(); defer { lock.unlock() }
            requested.append(url)
            return responses[url]
        }
        func requests(matching prefix: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return requested.filter { $0.hasPrefix(prefix) }
        }
    }

    static let store = Store()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        switch Self.store.response(for: url.absoluteString) {
        case .data(let data, let status)?:
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/xml"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        case .failure?, nil:
            client.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    override func stopLoading() {}
}

/// A Sparkle appcast with the given `<item>` bodies.
func appcast(items: [String]) -> Data {
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel>
        <title>Fancy Updates</title>
        <link>https://example.com/</link>
    \(items.joined(separator: "\n"))
      </channel>
    </rss>
    """
    return Data(xml.utf8)
}

func appcastItem(version: String, short: String? = nil, url: String = "https://example.com/dl.zip",
                 notes: String? = nil, channel: String? = nil, elementStyle: Bool = false) -> String {
    var body = "    <item>\n      <title>Version \(short ?? version)</title>\n"
    if let notes { body += "      <sparkle:releaseNotesLink>\(notes)</sparkle:releaseNotesLink>\n" }
    if let channel { body += "      <sparkle:channel>\(channel)</sparkle:channel>\n" }
    if elementStyle {
        body += "      <sparkle:version>\(version)</sparkle:version>\n"
        if let short { body += "      <sparkle:shortVersionString>\(short)</sparkle:shortVersionString>\n" }
        body += "      <enclosure url=\"\(url)\" length=\"1\" type=\"application/octet-stream\" />\n"
    } else {
        let shortAttr = short.map { " sparkle:shortVersionString=\"\($0)\"" } ?? ""
        body += "      <enclosure url=\"\(url)\" sparkle:version=\"\(version)\"\(shortAttr) length=\"1\" type=\"application/octet-stream\" />\n"
    }
    body += "    </item>"
    return body
}
