import UserNotifications

/// The delivery-only surface keeps offline tests out of OS permissions/tray APIs.
protocol NotificationDelivery: AnyObject {
    func deliveredRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removeDelivered(_ identifiers: [String])
    func setBadge(_ count: Int)
}

final class SystemNotificationDelivery: NotificationDelivery {
    func deliveredRequests() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().deliveredNotifications().map(\.request)
    }
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
    func setBadge(_ count: Int) { UNUserNotificationCenter.current().setBadgeCount(count) }
    func removeDelivered(_ identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

#if DEBUG
/// The ordinary mock host must not touch real delivered notifications either.
final class OfflineNotificationDelivery: NotificationDelivery {
    func deliveredRequests() async -> [UNNotificationRequest] { [] }
    func add(_ request: UNNotificationRequest) async throws {}
    func removeDelivered(_ identifiers: [String]) {}
    func setBadge(_ count: Int) {}
}
#endif
