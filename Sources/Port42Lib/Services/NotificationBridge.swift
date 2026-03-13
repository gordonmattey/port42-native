import Foundation
import UserNotifications

// MARK: - Notification Bridge (P-507)

/// Bridges port42.notify.* calls to UNUserNotificationCenter.
/// Handles permission request and notification delivery.
@MainActor
public final class NotificationBridge {

    private var authorized = false

    /// Ensure notification permission is granted at the system level.
    /// Called once before first notification; caches the result.
    private func ensureAuthorized() async -> Bool {
        if authorized { return true }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                authorized = granted
                return granted
            } catch {
                NSLog("[Port42] notification auth error: %@", error.localizedDescription)
                return false
            }
        default:
            return false
        }
    }

    /// Send a system notification.
    /// opts: { sound?: true, subtitle?: string, badge?: number }
    func send(title: String, body: String, opts: [String: Any]?) async -> [String: Any] {
        guard await ensureAuthorized() else {
            return ["error": "notification permission denied"]
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        if let subtitle = opts?["subtitle"] as? String {
            content.subtitle = subtitle
        }

        let playSound = opts?["sound"] as? Bool ?? true
        if playSound {
            content.sound = .default
        }

        let id = UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
            return ["ok": true, "id": id]
        } catch {
            return ["error": error.localizedDescription]
        }
    }
}
