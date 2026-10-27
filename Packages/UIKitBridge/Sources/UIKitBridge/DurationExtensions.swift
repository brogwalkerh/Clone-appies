import Foundation

extension Duration {
    /// Total length in seconds as a `Double`. `Duration` exposes only
    /// `components` (seconds + attoseconds), so this is the common conversion.
    var totalSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
