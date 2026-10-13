// Entry point of the privileged helper daemon (com.example.maccleaner.helper).
//
// launchd starts this process as root on demand when the app connects to the
// Mach service named in Resources/com.example.maccleaner.helper.plist. It is a
// pure XPC server: no UI, no CLI arguments, and a closed set of operations
// (ADR 0002, CLAUDE.md rule 5). Anything the process does is decided by
// `HelperCommandPlan` in the HelperProtocol package, never by a caller string.
@preconcurrency import Foundation
import HelperProtocol
import os

let logger = Logger(subsystem: HelperConstants.machServiceName, category: "main")

guard getuid() == 0 else {
    logger.fault("Refusing to start: helper must run as root (uid \(getuid(), privacy: .public)).")
    exit(EXIT_FAILURE)
}

// Never inherit an environment or umask from whoever launched us.
umask(0o022)

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

logger.notice("Helper v\(HelperConstants.version, privacy: .public) listening on \(HelperConstants.machServiceName, privacy: .public)")

// launchd's ExitTimeOut governs shutdown; the run loop serves connections until then.
RunLoop.main.run()
