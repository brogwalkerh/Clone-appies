import Foundation
import PerformanceModule
import ProtectionModule

/// A parsed `maccleaner://` URL (docs/CONTRACTS.md, "M3 — MenuAgent").
///
/// Routes:
/// - `maccleaner://smart-care`
/// - `maccleaner://cleanup[?scanner=<scanner id>]`
/// - `maccleaner://performance[?task=<maintenance task id>]`
/// - `maccleaner://protection[?scope=quick|normal|deep]`
/// - `maccleaner://schedule?id=<schedule uuid>` (the menu bar agent, when a schedule comes due)
/// - `maccleaner://action-set?id=<action set uuid>`
///
/// Parsing is pure so `DeepLinkRouterTests` can cover it without a window.
/// The route may be given as the host (`maccleaner://cleanup`) or, for callers
/// that produce a triple slash, as the first path component (`maccleaner:///cleanup`).
enum DeepLink: Hashable, Sendable {
    case smartCare
    case cleanup(scannerID: String?)
    case performance(taskID: String?)
    /// Opens Protection › Malware and starts a scan; an unknown or missing scope keeps the current one.
    case protection(scope: ScanScope?)
    /// Runs a due schedule's target in the background (no navigation).
    case schedule(id: UUID)
    /// Opens Smart Care and runs a My Tools action set.
    case actionSet(id: UUID)

    static let scheme = "maccleaner"

    enum Route: String, CaseIterable, Sendable {
        case smartCare = "smart-care"
        case cleanup
        case performance
        case protection
        case schedule
        case actionSet = "action-set"
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == DeepLink.scheme else {
            return nil
        }
        let hostRoute = components.host?.lowercased() ?? ""
        let pathRoute = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first.map { String($0).lowercased() } ?? ""
        let routeName = hostRoute.isEmpty ? pathRoute : hostRoute
        guard let route = Route(rawValue: routeName) else { return nil }

        let query = components.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let raw = query.first(where: { $0.name == name })?.value else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        switch route {
        case .smartCare:
            self = .smartCare
        case .cleanup:
            self = .cleanup(scannerID: value("scanner"))
        case .performance:
            self = .performance(taskID: value("task"))
        case .protection:
            self = .protection(scope: value("scope").flatMap { ScanScope(rawValue: $0.lowercased()) })
        case .schedule:
            guard let id = value("id").flatMap(UUID.init(uuidString:)) else { return nil }
            self = .schedule(id: id)
        case .actionSet:
            guard let id = value("id").flatMap(UUID.init(uuidString:)) else { return nil }
            self = .actionSet(id: id)
        }
    }

    var route: Route {
        switch self {
        case .smartCare: return .smartCare
        case .cleanup: return .cleanup
        case .performance: return .performance
        case .protection: return .protection
        case .schedule: return .schedule
        case .actionSet: return .actionSet
        }
    }

    /// The canonical URL for this link, e.g. for the menu bar agent to open.
    var url: URL? {
        var components = URLComponents()
        components.scheme = DeepLink.scheme
        components.host = route.rawValue
        switch self {
        case .smartCare:
            break
        case .cleanup(let scannerID):
            if let scannerID { components.queryItems = [URLQueryItem(name: "scanner", value: scannerID)] }
        case .performance(let taskID):
            if let taskID { components.queryItems = [URLQueryItem(name: "task", value: taskID)] }
        case .protection(let scope):
            if let scope { components.queryItems = [URLQueryItem(name: "scope", value: scope.rawValue)] }
        case .schedule(let id), .actionSet(let id):
            components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        }
        return components.url
    }
}

/// Turns a `DeepLink` into navigation and actions on `AppState`.
/// `MacCleanerApp` calls `open(_:)` from `.onOpenURL`.
@MainActor
struct DeepLinkRouter {
    let appState: AppState

    /// Returns `false` for URLs that are not ours or name an unknown route.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        route(link)
        return true
    }

    func route(_ link: DeepLink) {
        switch link {
        case .smartCare:
            appState.select(.smartCare)

        case .cleanup(let scannerID):
            appState.select(.cleanup)
            appState.runCleanup(restrictedTo: scannerID)

        case .performance(let taskID):
            appState.select(.performance)
            if let taskID, let task = MaintenanceCatalog.all.first(where: { $0.id == taskID }) {
                // The Performance screen consumes `pendingFocusTaskID`: it switches to
                // the Maintenance tab, runs the task when the helper allows, and
                // otherwise shows the helper install step.
                appState.maintenance.selectedTaskIDs = [task.id]
                appState.maintenance.pendingFocusTaskID = task.id
            }

        case .protection(let scope):
            // The menu bar agent's Protection Monitor row and Siri open this;
            // the scan starts right away so the user lands on live progress.
            appState.select(.protection)
            appState.runMalwareScan(scope: scope)

        case .schedule(let id):
            // Scheduled work runs where the user is; results arrive as a notification.
            Task { await appState.runSchedule(id: id) }

        case .actionSet(let id):
            appState.select(.smartCare)
            guard let set = appState.automation.actionSet(withID: id) else { return }
            Task { await appState.automation.run(set) }
        }
    }
}
