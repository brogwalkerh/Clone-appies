import Foundation
import CleanerCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Checks apps that ship a Sparkle `SUFeedURL` against their appcast.
///
/// Sparkle compares the feed's `sparkle:version` with `CFBundleVersion`; the
/// human-readable `sparkle:shortVersionString` is what gets reported. Apps
/// without a build number fall back to comparing short versions.
public struct SparkleUpdateSource: UpdateSource {
    private let session: URLSession
    private let maxConcurrentFetches: Int

    public init(session: URLSession = .shared) {
        self.init(session: session, maxConcurrentFetches: 4)
    }

    /// Additional initializer bounding the number of appcasts fetched at once.
    public init(session: URLSession, maxConcurrentFetches: Int) {
        self.session = session
        self.maxConcurrentFetches = max(1, maxConcurrentFetches)
    }

    public func check(_ apps: [InstalledApp]) async -> [AvailableUpdate] {
        let candidates = apps.filter { $0.sparkleFeedURL != nil }
        guard !candidates.isEmpty else { return [] }
        let session = self.session
        let limit = maxConcurrentFetches

        var results: [AvailableUpdate] = []
        await withTaskGroup(of: AvailableUpdate?.self) { group in
            var next = 0
            func enqueue() {
                let app = candidates[next]
                next += 1
                group.addTask { await Self.checkOne(app, session: session) }
            }
            while next < candidates.count && next < limit { enqueue() }
            for await result in group {
                if let result { results.append(result) }
                if next < candidates.count && !Task.isCancelled { enqueue() }
            }
        }
        return results.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    /// Fetches and evaluates one app's appcast. Any failure yields nil.
    static func checkOne(_ app: InstalledApp, session: URLSession) async -> AvailableUpdate? {
        guard let feedURL = app.sparkleFeedURL else { return nil }
        guard let data = try? await fetch(feedURL, session: session) else { return nil }
        guard let items = try? AppcastParser.parse(data), !items.isEmpty else { return nil }
        return update(for: app, from: items)
    }

    /// Picks the highest-versioned item and reports it when it is newer than
    /// the installed app.
    static func update(for app: InstalledApp, from items: [AppcastItem]) -> AvailableUpdate? {
        let eligible = items.filter { $0.version != nil && $0.channel == nil }
        guard let latest = eligible.max(by: { lhs, rhs in
            VersionComparator.compare(lhs.version ?? "", rhs.version ?? "") == .orderedAscending
        }), let latestVersion = latest.version else { return nil }

        let isNewer: Bool
        if let build = app.build, !build.isEmpty {
            isNewer = VersionComparator.isNewer(latestVersion, than: build)
        } else if let installed = app.version, !installed.isEmpty {
            isNewer = VersionComparator.isNewer(latest.shortVersion ?? latestVersion, than: installed)
        } else {
            return nil
        }
        guard isNewer else { return nil }
        return AvailableUpdate(app: app, latestVersion: latest.shortVersion ?? latestVersion,
                               downloadURL: latest.enclosureURL, releaseNotesURL: latest.releaseNotesURL,
                               source: .direct)
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("MacCleaner (Sparkle update check)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// One `<item>` of a Sparkle appcast.
public struct AppcastItem: Sendable, Hashable {
    public var title: String?
    public var version: String?            // sparkle:version (build number)
    public var shortVersion: String?       // sparkle:shortVersionString
    public var enclosureURL: URL?
    public var releaseNotesURL: URL?
    public var channel: String?            // sparkle:channel; nil = default channel
    public var minimumSystemVersion: String?

    public init(title: String? = nil, version: String? = nil, shortVersion: String? = nil,
                enclosureURL: URL? = nil, releaseNotesURL: URL? = nil, channel: String? = nil,
                minimumSystemVersion: String? = nil) {
        self.title = title
        self.version = version
        self.shortVersion = shortVersion
        self.enclosureURL = enclosureURL
        self.releaseNotesURL = releaseNotesURL
        self.channel = channel
        self.minimumSystemVersion = minimumSystemVersion
    }
}

/// Parses Sparkle appcast XML with `XMLParser` (FoundationXML on Linux).
public enum AppcastParser {
    public struct ParseError: Error, Sendable, Hashable {
        public let message: String
    }

    public static func parse(_ data: Data) throws -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        // On Linux `parse()` can return true for truncated input while still
        // recording `parserError`, so check both.
        let completed = parser.parse()
        if !completed || parser.parserError != nil {
            throw ParseError(message: parser.parserError.map { "\($0)" } ?? "malformed appcast")
        }
        guard delegate.sawRSS else { throw ParseError(message: "not an appcast") }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        var sawRSS = false
        private var current: AppcastItem?
        private var path: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            path.append(elementName)
            text = ""
            let name = elementName.lowercased()
            if name == "rss" { sawRSS = true }
            if name == "item" {
                current = AppcastItem()
                return
            }
            guard current != nil, path.dropLast().last?.lowercased() == "item" else { return }
            if name == "enclosure" {
                if let url = attributeDict["url"], let parsed = URL(string: url) {
                    current?.enclosureURL = parsed
                }
                if let version = attributeDict["sparkle:version"], !version.isEmpty {
                    current?.version = version
                }
                if let short = attributeDict["sparkle:shortVersionString"], !short.isEmpty {
                    current?.shortVersion = short
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            defer { path.removeLast(); text = "" }
            let name = elementName.lowercased()
            if name == "item" {
                if let current { items.append(current) }
                self.current = nil
                return
            }
            guard current != nil, path.dropLast().last?.lowercased() == "item" else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title":
                current?.title = value
            case "sparkle:version":
                if !value.isEmpty { current?.version = value }
            case "sparkle:shortversionstring":
                if !value.isEmpty { current?.shortVersion = value }
            case "sparkle:releasenoteslink":
                current?.releaseNotesURL = URL(string: value)
            case "sparkle:channel":
                if !value.isEmpty { current?.channel = value }
            case "sparkle:minimumsystemversion":
                if !value.isEmpty { current?.minimumSystemVersion = value }
            default:
                break
            }
        }
    }
}

extension URLSession {
    /// Loads `request` fully. Cross-platform replacement for the async
    /// `data(for:)` API, built on `dataTask` and a continuation.
    func bytes(for request: URLRequest) async throws -> (Data, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                box.store(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds the in-flight task so cancellation can reach it.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func store(_ task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}
