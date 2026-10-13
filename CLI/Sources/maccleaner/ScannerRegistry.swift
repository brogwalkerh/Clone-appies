import Foundation
import CleanerCore
import CleanupModule

/// The single place where scanners are registered for the CLI.
struct ScannerRegistry: Sendable {
    let scanners: [any CleanerScanner]

    init(scanners: [any CleanerScanner]) {
        // Keep the first scanner registered under a given id so duplicates never
        // run twice.
        var seen = Set<String>()
        self.scanners = scanners.filter { seen.insert($0.id).inserted }
    }

    /// Every scanner the tool knows about, in display order.
    static func builtIn() -> ScannerRegistry {
        var all: [any CleanerScanner] = []
        all.append(contentsOf: CleanupScanners.all())
        all.append(DemoScanner())
        return ScannerRegistry(scanners: all)
    }

    func scanner(withID id: String) -> (any CleanerScanner)? {
        scanners.first { $0.id == id }
    }

    /// Scanners restricted to `module` (when given) and to `scannerIDs` (when
    /// non-empty). Unknown ids are an error so typos never silently scan nothing.
    func filtered(module: ModuleID? = nil, scannerIDs: [String] = []) throws -> [any CleanerScanner] {
        let known = Set(scanners.map { $0.id })
        for id in scannerIDs where !known.contains(id) {
            throw RegistryError.unknownScanner(id, available: scanners.map { $0.id })
        }
        let wanted = Set(scannerIDs)
        return scanners.filter { scanner in
            if let module, scanner.module != module { return false }
            if !wanted.isEmpty, !wanted.contains(scanner.id) { return false }
            return true
        }
    }
}

enum RegistryError: Error, Hashable, CustomStringConvertible {
    case unknownScanner(String, available: [String])

    var description: String {
        switch self {
        case .unknownScanner(let id, let available):
            return "Unknown scanner '\(id)'. Available: \(available.joined(separator: ", "))"
        }
    }
}
