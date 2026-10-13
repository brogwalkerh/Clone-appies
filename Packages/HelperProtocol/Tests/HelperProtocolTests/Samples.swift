import Foundation
@testable import HelperProtocol

extension HelperOperation {
    /// One representative, *valid* sample per case. A test asserts this list
    /// covers every case so new operations cannot be added without a plan.
    static var allSamples: [HelperOperation] {
        [
            .ping,
            .freePurgeableSpace,
            .flushDNSCache,
            .runPeriodicScripts(.weekly),
            .reindexSpotlight(volume: "/"),
            .rebuildLaunchServices,
            .thinLocalSnapshots(bytesToFree: 1_000_000),
            .removeSystemCache(path: "/Library/Caches/com.example.something"),
            .setLaunchDaemonEnabled(label: "com.example.daemon", enabled: false),
            .resetBluetoothModule,
            .speedUpMail,
        ]
    }

    /// Compile-time exhaustiveness: this switch fails to build when a case is
    /// added, which is the reminder to extend `allSamples` and the plan tests.
    static func caseIndex(of operation: HelperOperation) -> Int {
        switch operation {
        case .ping: return 0
        case .freePurgeableSpace: return 1
        case .flushDNSCache: return 2
        case .runPeriodicScripts: return 3
        case .reindexSpotlight: return 4
        case .rebuildLaunchServices: return 5
        case .thinLocalSnapshots: return 6
        case .removeSystemCache: return 7
        case .setLaunchDaemonEnabled: return 8
        case .resetBluetoothModule: return 9
        case .speedUpMail: return 10
        }
    }

    static let caseCount = 11
}

let validHome = "/Users/alice"

func request(_ operation: HelperOperation, home: String = validHome) -> HelperRequest {
    HelperRequest(operation: operation, callerHome: home)
}
