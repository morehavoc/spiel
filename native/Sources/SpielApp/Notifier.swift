import AppKit
import Foundation
import UserNotifications

enum Notifier {
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
