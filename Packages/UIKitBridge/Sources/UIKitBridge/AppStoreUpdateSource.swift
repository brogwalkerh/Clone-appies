import Foundation
import ApplicationsModule

/// `UpdateSource` for Mac App Store apps via the public iTunes Lookup API
/// (`https://itunes.apple.com/lookup?bundleId=…&entity=macSoftware`), which
/// needs no receipt validation or StoreKit entitlement.
///
/// Bundle ids are sent in batches of up to `batchSize` where the API accepts a
/// comma-separated list; apps missing from a batched answer are retried one by
/// one, since the lookup endpoint has historically honoured only the first
/// `bundleId` in some regions.
public struct AppStoreUpdateSource: UpdateSource {
    public static let batchSize = 20

    private let session: URLSession
    private let endpoint: URL?

    public init(session: URLSession = .shared) {
        self.session = session
        self.endpoint = URL(string: "https://itunes.apple.com/lookup")
    }

    public func check(_ apps: [InstalledApp]) async -> [AvailableUpdate] {
        let candidates = apps.filter { $0.source == .appStore && !($0.bundleIdentifier ?? "").isEmpty }
        guard !candidates.isEmpty, endpoint != nil else { return [] }

        var results: [String: LookupResult] = [:]
        for batch in candidates.chunked(into: AppStoreUpdateSource.batchSize) {
            let ids = batch.compactMap(\.bundleIdentifier)
            let found = await lookup(bundleIDs: ids)
            results.merge(found) { current, _ in current }

            let missing = ids.filter { results[$0.lowercased()] == nil }
            if ids.count > 1, !missing.isEmpty {
                for id in missing {
                    let single = await lookup(bundleIDs: [id])
                    results.merge(single) { current, _ in current }
                }
            }
        }

        return candidates.compactMap { app -> AvailableUpdate? in
            guard let bundleID = app.bundleIdentifier,
                  let result = results[bundleID.lowercased()],
                  let latest = result.version, !latest.isEmpty
            else { return nil }
            if let installed = app.version,
               VersionComparator.compare(installed, latest) != .orderedAscending {
                return nil
            }
            let page = result.trackViewUrl.flatMap(URL.init(string:))
            return AvailableUpdate(app: app,
                                   latestVersion: latest,
                                   downloadURL: page,
                                   releaseNotesURL: page,
                                   source: .appStore)
        }
    }

    // MARK: Network

    /// One lookup request; keys of the returned dictionary are lowercased bundle ids.
    private func lookup(bundleIDs: [String]) async -> [String: LookupResult] {
        guard let endpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { return [:] }
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIDs.joined(separator: ",")),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "limit", value: String(max(bundleIDs.count, 1))),
        ]
        guard let url = components.url else { return [:] }

        guard let fetched = try? await session.data(from: url) else { return [:] }
        let data = fetched.0
        if let http = fetched.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode(LookupResponse.self, from: data) else {
            return [:]
        }
        var byBundle: [String: LookupResult] = [:]
        for result in decoded.results {
            guard let bundleID = result.bundleId else { continue }
            byBundle[bundleID.lowercased()] = result
        }
        return byBundle
    }

    // MARK: JSON

    struct LookupResponse: Decodable, Sendable {
        var results: [LookupResult]

        private enum CodingKeys: String, CodingKey { case results }

        init(results: [LookupResult]) {
            self.results = results
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            results = try container.decodeIfPresent([LookupResult].self, forKey: .results) ?? []
        }
    }

    struct LookupResult: Decodable, Sendable {
        var bundleId: String?
        var version: String?
        var trackViewUrl: String?
        var releaseNotes: String?
        var trackName: String?
    }
}

extension Array {
    /// Splits the array into consecutive slices of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
