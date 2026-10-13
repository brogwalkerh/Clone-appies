import Foundation
import CleanerCore

public enum ClutterScanners {
    /// All My Clutter scanners, in display order. Similar Images is only
    /// included when a feature-print provider is available (macOS: Vision).
    public static func all(imageFeatures: (any ImageFeatureProvider)? = nil) -> [any CleanerScanner] {
        var scanners: [any CleanerScanner] = [
            LargeOldFilesScanner(),
            DuplicatesScanner(),
            DownloadsScanner(),
        ]
        if let imageFeatures {
            scanners.append(SimilarImagesScanner(provider: imageFeatures))
        }
        return scanners
    }
}
