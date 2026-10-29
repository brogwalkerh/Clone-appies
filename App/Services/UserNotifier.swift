import Foundation
import UserNotifications

/// Posts a system notification for results that arrive while the user is
/// elsewhere (scheduled scans). Silently does nothing until the user has
/// allowed notifications in onboarding.
enum UserNotifier {
    /// `UNNotificationRequest` is not `Sendable`, so only strings cross into
    /// the task and the request is assembled there (same as the menu bar agent).
    static func post(title: String, body: String, link: String?) {
        Task.detached(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let link { content.userInfo = ["route": link] }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
