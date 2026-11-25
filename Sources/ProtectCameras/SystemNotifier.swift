import Foundation
import UserNotifications

/// macOS banners for Protect events, with the snapshot attached. Clicking one shows the camera.
@MainActor
enum SystemNotifier {
    /// UNUserNotificationCenter only works inside an app bundle (not under `swift run`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    private static let delegate = Delegate()
    static var onOpen: ((_ eventID: String, _ cameraID: String?) -> Void)?

    static func setUp(onOpen: @escaping (String, String?) -> Void) {
        guard available else { return }
        self.onOpen = onOpen
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        guard available else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func post(_ event: ProtectEvent, thumbnail: URL?, sound: Bool) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = event.cameraName ?? "Protect"
        content.body = event.summary
        content.userInfo = ["event": event.id, "camera": event.cameraID ?? ""]
        content.threadIdentifier = event.cameraID ?? "protect"
        if sound { content.sound = .default }
        if let thumbnail, let attachment = attachment(from: thumbnail) {
            content.attachments = [attachment]
        }
        Debug.log("notify: \(content.title) — \(content.body)")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "event-\(event.id)", content: content, trigger: nil))
    }

    /// The system moves attachment files into its own store, so hand it a copy.
    private static func attachment(from url: URL) -> UNNotificationAttachment? {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return try UNNotificationAttachment(identifier: "snapshot", url: copy, options: nil)
        } catch {
            Debug.log("attachment failed: \(error)")
            return nil
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let info = response.notification.request.content.userInfo
            let eventID = info["event"] as? String
            let cameraID = (info["camera"] as? String).nonEmpty
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let eventID { SystemNotifier.onOpen?(eventID, cameraID) }
                }
            }
            completionHandler()
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list, .sound])
        }
    }
}
