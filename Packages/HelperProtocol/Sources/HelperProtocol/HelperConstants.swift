import Foundation

public enum HelperConstants {
    /// launchd label, Mach service name and the helper's bundle identifier.
    public static let machServiceName = "com.example.maccleaner.helper"
    /// Bundle identifier of the only process allowed to talk to the helper.
    public static let appBundleIdentifier = "com.example.maccleaner"
    /// Wire protocol version. The app compares it with `version(reply:)` and
    /// reinstalls the helper on mismatch; it never falls back to a looser contract.
    public static let version = "1"

    /// Placeholder for the Apple Developer Team ID. `release.yml` substitutes
    /// the real `APPLE_TEAM_ID` into both requirement strings at build time;
    /// development builds keep the placeholder, which matches nothing, so an
    /// unsigned app cannot talk to an unsigned helper by accident.
    public static let teamIDPlaceholder = "TEAMID_PLACEHOLDER"

    /// Designated requirement the helper enforces on every connecting process:
    /// Apple-issued Developer ID chain, our app's identifier, our Team ID.
    public static let clientRequirement =
        "anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIDPlaceholder)\""

    /// Requirement the app sets on its `NSXPCConnection` so it only ever talks
    /// to our own helper binary.
    public static let helperRequirement =
        "anchor apple generic and identifier \"\(machServiceName)\" and certificate leaf[subject.OU] = \"\(teamIDPlaceholder)\""
}
