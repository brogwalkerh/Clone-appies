import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ApplicationsModule
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("SparkleUpdateSource")
struct SparkleUpdateSourceTests {
    let source = SparkleUpdateSource(session: StubURLProtocol.makeSession())

    /// Unique feed URL per test so canned responses never collide.
    func feed(_ tag: String) -> String { "https://updates.example.com/\(tag)/appcast.xml" }

    func app(_ tag: String, version: String? = "1.2.3", build: String? = "456") -> InstalledApp {
        makeApp(name: "Fancy \(tag)", id: "com.vendor.fancy", version: version, build: build, feed: feed(tag))
    }

    @Test func newerVersionInFeedIsReported() async throws {
        StubURLProtocol.store.set(feed("newer"), .data(appcast(items: [
            appcastItem(version: "455", short: "1.2.2", url: "https://example.com/old.zip"),
            appcastItem(version: "457", short: "1.2.4", url: "https://example.com/new.zip",
                        notes: "https://example.com/notes/1.2.4.html"),
            appcastItem(version: "456", short: "1.2.3"),
        ])))
        let updates = await source.check([app("newer")])
        let update = try #require(updates.first)
        #expect(updates.count == 1)
        #expect(update.latestVersion == "1.2.4")
        #expect(update.downloadURL == URL(string: "https://example.com/new.zip"))
        #expect(update.releaseNotesURL == URL(string: "https://example.com/notes/1.2.4.html"))
        #expect(update.source == .direct)
        #expect(update.app.sparkleFeedURL == URL(string: feed("newer")))
    }

    @Test func equalVersionIsNotAnUpdate() async {
        StubURLProtocol.store.set(feed("equal"), .data(appcast(items: [appcastItem(version: "456", short: "1.2.3")])))
        #expect(await source.check([app("equal")]).isEmpty)
    }

    @Test func olderVersionIsNotAnUpdate() async {
        StubURLProtocol.store.set(feed("older"), .data(appcast(items: [appcastItem(version: "400", short: "1.1.0")])))
        #expect(await source.check([app("older")]).isEmpty)
    }

    @Test func malformedXMLYieldsNoUpdate() async {
        StubURLProtocol.store.set(feed("malformed"), .data(Data("<rss><channel><item><enclosure sparkle:version=\"999\"".utf8)))
        #expect(await source.check([app("malformed")]).isEmpty)
        StubURLProtocol.store.set(feed("html"), .data(Data("<html><body>Not Found</body></html>".utf8)))
        #expect(await source.check([app("html")]).isEmpty)
    }

    @Test func networkErrorYieldsNoUpdate() async {
        StubURLProtocol.store.set(feed("error"), .failure)
        #expect(await source.check([app("error")]).isEmpty)
        #expect(await source.check([app("unregistered")]).isEmpty)
        StubURLProtocol.store.set(feed("404"), .data(appcast(items: [appcastItem(version: "999")]), status: 404))
        #expect(await source.check([app("404")]).isEmpty)
    }

    @Test func elementStyleVersionsAreSupported() async throws {
        StubURLProtocol.store.set(feed("elements"), .data(appcast(items: [
            appcastItem(version: "500", short: "1.3.0", url: "https://example.com/e.zip", elementStyle: true),
        ])))
        let updates = await source.check([app("elements")])
        let update = try #require(updates.first)
        #expect(update.latestVersion == "1.3.0")
        #expect(update.downloadURL == URL(string: "https://example.com/e.zip"))
    }

    @Test func betaChannelItemsAreIgnored() async {
        StubURLProtocol.store.set(feed("beta"), .data(appcast(items: [
            appcastItem(version: "600", short: "2.0b1", channel: "beta"),
            appcastItem(version: "456", short: "1.2.3"),
        ])))
        #expect(await source.check([app("beta")]).isEmpty)
    }

    @Test func appsWithoutBuildFallBackToShortVersion() async throws {
        StubURLProtocol.store.set(feed("nobuild"), .data(appcast(items: [appcastItem(version: "2.0", short: "2.0")])))
        let updates = await source.check([app("nobuild", version: "1.9", build: nil)])
        #expect(updates.first?.latestVersion == "2.0")
        #expect(await source.check([app("nobuild", version: "2.0", build: nil)]).isEmpty)
        #expect(await source.check([app("nobuild", version: nil, build: nil)]).isEmpty)
    }

    @Test func appsWithoutFeedAreNotFetched() async {
        let silent = makeApp(name: "Silent", id: "com.vendor.silent")
        #expect(await source.check([silent]).isEmpty)
        #expect(StubURLProtocol.store.requests(matching: "https://updates.example.com/silent").isEmpty)
        #expect(await source.check([]).isEmpty)
    }

    @Test func manyAppsAreCheckedConcurrentlyAndSorted() async {
        var apps: [InstalledApp] = []
        for index in 0..<10 {
            let tag = "many\(index)"
            StubURLProtocol.store.set(feed(tag), .data(appcast(items: [appcastItem(version: "\(1_000 + index)", short: "9.\(index)")])))
            apps.append(makeApp(name: "App \(9 - index)", id: "com.vendor.many\(index)",
                                path: "/Applications/Many\(index).app", feed: feed(tag)))
        }
        let updates = await SparkleUpdateSource(session: StubURLProtocol.makeSession(), maxConcurrentFetches: 3).check(apps)
        #expect(updates.count == 10)
        #expect(updates.map(\.app.name) == updates.map(\.app.name).sorted())
    }

    @Test func parserReadsAllItemFields() throws {
        let items = try AppcastParser.parse(appcast(items: [
            appcastItem(version: "457", short: "1.2.4", notes: "https://example.com/n.html"),
            "<item><title>Bare</title><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url=\"https://example.com/b.zip\" /></item>",
        ]))
        #expect(items.count == 2)
        #expect(items[0].title == "Version 1.2.4")
        #expect(items[0].version == "457")
        #expect(items[0].shortVersion == "1.2.4")
        #expect(items[0].releaseNotesURL == URL(string: "https://example.com/n.html"))
        #expect(items[0].channel == nil)
        #expect(items[1].version == nil)
        #expect(items[1].minimumSystemVersion == "14.0")
        #expect(items[1].enclosureURL == URL(string: "https://example.com/b.zip"))
        #expect(throws: AppcastParser.ParseError.self) { try AppcastParser.parse(Data("<rss>".utf8)) }
        #expect(throws: AppcastParser.ParseError.self) { try AppcastParser.parse(Data("<html/>".utf8)) }
    }

    @Test func updateSelectionPicksHighestVersion() {
        let items = [
            AppcastItem(version: "10", shortVersion: "1.0"),
            AppcastItem(version: "30", shortVersion: "3.0", enclosureURL: URL(string: "https://e/3.zip")),
            AppcastItem(version: "20", shortVersion: "2.0"),
            AppcastItem(version: nil, shortVersion: "99.0"),
        ]
        let installed = makeApp(name: "X", id: "com.x.y", version: "2.0", build: "20")
        let update = SparkleUpdateSource.update(for: installed, from: items)
        #expect(update?.latestVersion == "3.0")
        #expect(update?.downloadURL == URL(string: "https://e/3.zip"))
        #expect(SparkleUpdateSource.update(for: installed, from: []) == nil)
    }
}
