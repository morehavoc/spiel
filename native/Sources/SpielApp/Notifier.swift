import AppKit
import Foundation
import UserNotifications

enum Notifier {
    /// Ask once, at launch. Asking lazily inside `post` meant the first message the
    /// app ever had for the user arrived at the same instant as the permission dialog
    /// and was lost.
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            NSLog("Spiel: notification permission %@", granted ? "granted" : "denied")
        }
    }

    /// Best-effort user notification. Falls back to NSLog when unbundled (running
    /// straight out of .build has no bundle identifier, so UNUserNotificationCenter
    /// throws rather than returning an error).
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("Spiel: %@ — %@", title, body)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                NSLog("Spiel: %@ — %@", title, body)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}
