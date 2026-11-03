import Foundation

/// Donations (PLAN.md §6): Featherduster is free; GitHub Sponsors is the only
/// way to support it. Nothing is gated behind a donation.
enum SupportLinks {
    /// GitHub Sponsors page for the project owner. Opened in the browser only.
    static let sponsorsURLString = "https://github.com/sponsors/brogwalkerh"

    static var sponsors: URL {
        // The literal is a well-formed URL; `URL(string:)` only fails on malformed input.
        URL(string: sponsorsURLString) ?? URL(fileURLWithPath: "/")
    }
}

/// When Smart Care shows its one quiet "Support Featherduster" card: only after
/// the app has done real work for this Mac, and never again once the person
/// has answered it (sponsored or said no). Pure, so it is unit-tested.
struct SupportPromptPolicy: Sendable, Hashable {
    /// Bytes reclaimed (removals and maintenance minus undos, all time) before asking.
    var minimumBytesReclaimed: Int64 = 1_000_000_000

    func shouldShow(bytesReclaimed: Int64, answered: Bool) -> Bool {
        !answered && bytesReclaimed >= minimumBytesReclaimed
    }
}
