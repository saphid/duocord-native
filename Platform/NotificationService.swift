import UIKit
import UserNotifications
import os

/// Local message alert categories. Reply and Mark as Read both need an
/// unlocked device and run without bringing the app forward.
nonisolated enum MessageAlertAction {
    static let category = "duocord.message"
    static let readOnlyCategory = "duocord.message.readonly"
    static let reply = "duocord.message.reply"
    static let markRead = "duocord.message.markRead"

    static var categories: Set<UNNotificationCategory> {
        let replyAction = UNTextInputNotificationAction(identifier: reply, title: "Reply", options: [.authenticationRequired],
                                                        textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let readAction = UNNotificationAction(identifier: markRead, title: "Mark as Read", options: [.authenticationRequired])
        return [UNNotificationCategory(identifier: category, actions: [replyAction, readAction], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: readOnlyCategory, actions: [readAction], intentIdentifiers: [], options: [])]
    }
}

/// A notification response as plain values, so routing is testable without
/// constructing `UNNotificationResponse`. Typed text is kept only for Reply.
nonisolated struct NotificationActionResponse: Equatable, Sendable {
    enum Action: Equatable, Sendable { case open, reply(String), markRead, ignore }
    var action: Action
    var identifier: String
    var info: [String: String]

    init(actionIdentifier: String, identifier: String, userInfo: [AnyHashable: Any], text: String? = nil) {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = .open
        case MessageAlertAction.reply: action = .reply(text ?? "")
        case MessageAlertAction.markRead: action = .markRead
        default: action = .ignore // dismissal and unknown identifiers neither open nor write
        }
        self.identifier = identifier
        var info: [String: String] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        self.info = info
    }
}

/// This app's own local alert, required before an action writes. The current
/// account is the authority; the posting session only scopes alert removal.
nonisolated struct LocalAlertOrigin: Equatable, Sendable {
    let channel: Snowflake
    let message: Snowflake
    let account: Snowflake
    let session: UUID

    init?(_ response: NotificationActionResponse) {
        let info = response.info
        func id(_ key: String) -> Snowflake? {
            guard let raw = info[key], let value = Snowflake(raw), value.raw > 0, raw == value.description else { return nil }
            return value
        }
        guard info["duocordLocal"] == "1", let channel = id("channel"), let message = id("message"),
              let account = id("duocordAccount"), let raw = info["duocordSession"],
              let session = UUID(uuidString: raw), raw == session.uuidString,
              response.identifier == "msg-\(message)-\(raw)" else { return nil }
        self.channel = channel; self.message = message; self.account = account; self.session = session
    }
}

nonisolated enum NotificationActionOutcome: Equatable, Sendable {
    case opened, ignored, refused, unchanged, sent, sendFailed, markedRead, readFailed
}

/// Native notifications for new messages (decided by the store's
/// notification rules), the app icon badge, and taps that open the
/// message's channel.
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private var authorized = false
    private let delivery: NotificationDelivery
    private let offlineHost: Bool
    private let loadAttachment: (URL) async -> UNNotificationAttachment?

    init(delivery: NotificationDelivery? = nil, authorized: Bool = false,
         loadAttachment: @escaping (URL) async -> UNNotificationAttachment? = NotificationService.attachment) {
        #if DEBUG
        offlineHost = delivery == nil && UserDefaults.standard.bool(forKey: "DuocordMock")
        self.delivery = delivery ?? (offlineHost ? OfflineNotificationDelivery() : SystemNotificationDelivery())
        #else
        offlineHost = false
        self.delivery = delivery ?? SystemNotificationDelivery()
        #endif
        self.authorized = authorized
        self.loadAttachment = loadAttachment
        super.init()
    }
    private struct ReadScope: Equatable {
        let store: ObjectIdentifier
        let reads: UUID
        let people: UUID
        let account: Snowflake

        init?(_ store: DiscordStore) {
            guard let account = store.me?.id else { return nil }
            self.store = ObjectIdentifier(store)
            reads = store.readEpoch; people = store.peopleEpoch; self.account = account
        }
    }
    private var readScope: ReadScope?
    private var deliverySession = UUID()
    /// High-water marks exist only for known channels in the current session.
    /// Manual unread cannot recreate alerts already read and removed locally.
    private var readThrough: [Snowflake: Snowflake] = [:]

    /// Each suspended post retains accepted-read cancellation even if its
    /// channel's high-water mark is pruned before the post completes.
    private final class PendingPost {
        let channel: Snowflake
        let message: Snowflake
        var cancelled = false
        init(channel: Snowflake, message: Snowflake) {
            self.channel = channel; self.message = message
        }
    }
    private var pendingPosts: [UUID: PendingPost] = [:]

    func resetReadSession() {
        for post in pendingPosts.values { post.cancelled = true }
        pendingPosts = [:]
        readScope = nil
        deliverySession = UUID()
        readThrough = [:]
    }

    private func scope(for store: DiscordStore) -> ReadScope? {
        guard let scope = ReadScope(store) else { resetReadSession(); return nil }
        if readScope != scope {
            resetReadSession()
            readScope = scope
        }
        readThrough = readThrough.filter { store.channel($0.key) != nil }
        return scope
    }

    private func isCurrent(_ scope: ReadScope, session: UUID, store: DiscordStore) -> Bool {
        readScope == scope && deliverySession == session && ReadScope(store) == scope
    }

    #if DEBUG
    /// Captures delivery decisions in offline model tests without OS alerts.
    var mockPostObserver: ((Snowflake) -> Void)?
    #endif
    private var pendingTap: (channel: Snowflake, message: Snowflake)?
    private let log = Logger(subsystem: "com.saphid.duocord.native", category: "notify")
    /// Set by the app: opens a channel at a message.
    var onOpen: ((Snowflake, Snowflake) -> Void)?
    /// Set by the app: Reply or Mark as Read for an alert of this app's own.
    var onAction: (@MainActor (NotificationActionResponse.Action, LocalAlertOrigin) async -> NotificationActionOutcome)?

    func activate() {
        center.delegate = self
        center.setNotificationCategories(MessageAlertAction.categories)
        Task { await refreshAuthorization() }
    }

    /// Reply is offered only where a send would be allowed now. A 1:1 DM with
    /// someone now blocked takes no replies from an alert.
    static func canQuickReply(in channel: Channel?, store: DiscordStore) -> Bool {
        guard let channel, channel.type.isTextLike, store.canSend(in: channel) else { return false }
        return channel.type != .dm || !store.recipients(of: channel).contains { store.isBlocked($0.id) }
    }

    func requestAuthorizationIfNeeded() {
        guard !offlineHost else { return }
        guard !UserDefaults.standard.bool(forKey: "DuocordNoNotificationPrompt") else { return }
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            await refreshAuthorization()
        }
    }

    private func refreshAuthorization() async {
        guard !offlineHost else { return }
        let status = await center.notificationSettings().authorizationStatus
        authorized = [.authorized, .provisional, .ephemeral].contains(status)
    }

    func setBadge(_ count: Int) {
        guard authorized else { return }
        delivery.setBadge(count)
    }

    /// Title = sender, subtitle = "#channel · Server" (or the group name),
    /// body = the message as plain text; grouped by channel.
    func post(message: Message, store: DiscordStore) {
        guard !store.isBlocked(message.author.id) else { return }
        #if DEBUG
        if let mockPostObserver { mockPostObserver(message.id); return }
        #endif
        guard authorized else { return }
        guard let scope = scope(for: store),
              message.id > readThrough[message.channelID, default: 0] else { return }
        let session = deliverySession
        let epoch = store.peopleEpoch
        let content = UNMutableNotificationContent()
        let channel = store.channel(message.channelID)
        let guild = channel?.guildID.flatMap { store.guilds[$0] }
        content.title = store.displayName(for: message.author, in: guild?.id)
        if let channel {
            if let guild {
                content.subtitle = "#\(channel.name ?? "") · \(guild.name)"
            } else if channel.type == .groupDM {
                content.subtitle = store.dmName(channel)
            }
        }
        let context = MessageBuilder(store: store, guildID: guild?.id).context()
        var body = MarkdownRenderer.plainText(message.content, context: context)
        if body.isEmpty {
            body = message.attachments.isEmpty ? (message.embeds.isEmpty ? "Sent a message" : "Sent an embed")
                : "Sent \(message.attachments.count == 1 ? "an attachment" : "\(message.attachments.count) attachments")"
        }
        content.body = String(body.prefix(1000))
        content.sound = .default
        content.threadIdentifier = message.channelID.description
        content.categoryIdentifier = Self.canQuickReply(in: channel, store: store)
            ? MessageAlertAction.category : MessageAlertAction.readOnlyCategory
        content.userInfo = ["channel": message.channelID.description, "message": message.id.description,
                            "duocordAccount": scope.account.description,
                            "duocordSession": session.uuidString, "duocordLocal": "1"]
        content.targetContentIdentifier = message.channelID.description
        let request = UNNotificationRequest(identifier: "msg-\(message.id)-\(session.uuidString)", content: content, trigger: nil)
        let postID = UUID()
        let pending = PendingPost(channel: message.channelID, message: message.id)
        pendingPosts[postID] = pending
        Task {
            defer { pendingPosts[postID] = nil }
            guard store.peopleEpoch == epoch, !store.isBlocked(message.author.id),
                  !pending.cancelled,
                  isCurrent(scope, session: session, store: store),
                  message.id > readThrough[message.channelID, default: 0] else { return }
            if let avatar = message.author.avatarURL(size: 128), let attachment = await loadAttachment(avatar) {
                content.attachments = [attachment]
            }
            guard store.peopleEpoch == epoch, !store.isBlocked(message.author.id),
                  !pending.cancelled,
                  isCurrent(scope, session: session, store: store),
                  message.id > readThrough[message.channelID, default: 0] else { return }
            do {
                try await delivery.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
            } catch { return }
            // add may already be in flight when a read/reset occurs. Its unique
            // session-qualified ID cannot remove a replacement session's alert.
            if pending.cancelled || !isCurrent(scope, session: session, store: store) ||
                message.id <= readThrough[message.channelID, default: 0] {
                delivery.removeDelivered([request.identifier])
            }
        }
    }

    /// Called only with the store's accepted read extent. Local reading is
    /// sufficient even when automatic server acknowledgements are disabled.
    func clear(channel: Snowflake, through boundary: Snowflake, store: DiscordStore) {
        guard boundary > 0, store.channel(channel) != nil, let scope = scope(for: store),
              boundary > readThrough[channel, default: 0] else { return }
        readThrough[channel] = boundary
        for post in pendingPosts.values where post.channel == channel && post.message <= boundary {
            post.cancelled = true
        }
        let session = deliverySession
        Task {
            let delivered = await delivery.deliveredRequests()
            guard isCurrent(scope, session: session, store: store) else { return }
            let ids = delivered.filter { request in
                let content = request.content, info = content.userInfo
                // Old msg-ID records have no account provenance. Preserve them;
                // threadIdentifier alone is never ownership/boundary authority.
                guard info["duocordLocal"] as? String == "1",
                      info["duocordAccount"] as? String == scope.account.description,
                      let recordSession = info["duocordSession"] as? String,
                      UUID(uuidString: recordSession) != nil,
                      info["channel"] as? String == channel.description,
                      content.threadIdentifier == channel.description,
                      let raw = info["message"] as? String, let message = Snowflake(raw),
                      raw == message.description, message > 0, message <= boundary,
                      request.identifier == "msg-\(message)-\(recordSession)" else { return false }
                return true
            }.map(\.identifier)
            if !ids.isEmpty { delivery.removeDelivered(ids) }
        }
    }

    /// Only the default action opens. Only Reply and Mark as Read on an alert
    /// with this app's own provenance can write; anything else does nothing.
    @discardableResult
    func handle(_ response: NotificationActionResponse) async -> NotificationActionOutcome {
        switch response.action {
        case .open:
            guard let channel = response.info["channel"].flatMap(Snowflake.init),
                  let message = response.info["message"].flatMap(Snowflake.init) else { return .ignored }
            handleTap(channel: channel, message: message)
            return .opened
        case .ignore:
            return .ignored
        case .reply, .markRead:
            guard let origin = LocalAlertOrigin(response), let onAction else { return .refused }
            return await onAction(response.action, origin)
        }
    }

    func handleTap(channel: Snowflake, message: Snowflake) {
        pendingTap = (channel, message)
        if UIApplication.shared.applicationState == .active { flushPendingTap() }
    }

    func flushPendingTap() {
        guard let tap = pendingTap, let onOpen else { return }
        pendingTap = nil
        onOpen(tap.channel, tap.message)
    }

    private static func attachment(for url: URL) async -> UNNotificationAttachment? {
        guard url.scheme == "https", let host = url.host, ["cdn.discordapp.com", "media.discordapp.net"].contains(host) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "avatar-\(UUID().uuidString).png")
        guard let image = UIImage(data: data)?.pngData(), (try? image.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "avatar", url: file)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let text = response.actionIdentifier == MessageAlertAction.reply ? (response as? UNTextInputNotificationResponse)?.userText : nil
        let value = NotificationActionResponse(actionIdentifier: response.actionIdentifier, identifier: request.identifier,
                                               userInfo: request.content.userInfo, text: text)
        // Awaited: the action's readiness wait is bounded by the app.
        await handle(value)
    }
}
