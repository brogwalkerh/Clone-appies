import Foundation
#if canImport(AppKit)
import AppKit

/// Finder icons for app bundles via `NSWorkspace`, with a small main-actor cache
/// so a long Uninstaller list does not hit the icon services on every row redraw.
@MainActor
public enum AppIconProvider {
    private static var cache: [URL: NSImage] = [:]
    private static let cacheLimit = 512

    /// The icon Finder shows for `bundleURL`. Falls back to the generic
    /// application icon when the bundle cannot be read.
    public static func icon(for bundleURL: URL) -> NSImage {
        let key = bundleURL.standardizedFileURL
        if let cached = cache[key] {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: key.path(percentEncoded: false))
        if cache.count >= cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = image
        return image
    }

    /// Drops every cached icon, e.g. after the app inventory is refreshed.
    public static func clearCache() {
        cache.removeAll()
    }
}
#endif
