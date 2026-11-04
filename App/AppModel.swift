import Foundation
import Observation
import SwiftUI
import UIKit
import os

struct Draft: Equatable {
    var text = "" {
        didSet { tokens = Autocomplete.rebase(tokens, from: oldValue, to: text) }
    }
    var replyTo: Message?
    var attachments: [DraftAttachment] = []
    /// Set while the composer edits one of your messages (Save replaces Send).
    var editing: Message?
    /// Mentions, channels and custom emoji inserted from autocomplete: shown
    /// readable in the field, sent in Discord's form (see `Autocomplete.wireText`).
    var tokens: [ComposerToken] = []
}

/// A short message shown near the composer when something you did didn't stick.
struct Toast: Equatable {
    var text: String
    var token = UUID()
}

struct DraftAttachment: Identifiable, Equatable {
    let id = UUID()
    var filename: String
    var data: Data
    var contentType: String
    var thumbnail: UIImage?

    static func == (a: DraftAttachment, b: DraftAttachment) -> Bool { a.id == b.id }
}

enum AppSheet: Identifiable, Equatable {
    case search, pins, inbox, settings, threads(Snowflake), user(Snowflake), media(MediaItem), members, servers
    /// Who reacted to a message, opened on one emoji's tab.
    case reactions(channel: Snowflake, message: Snowflake, emoji: String)
    case emojiPicker(channel: Snowflake, message: Snowflake)
    case notifications(NotificationTarget)
    case friends

    var id: String {
        switch self {
        case .friends: "friends"
        case .search: "search"
        case .pins: "pins"
        case .inbox: "inbox"
        case .settings: "settings"
        case .notifications(let target): "notifications-\(target.resource)-\(target.channelID?.description ?? "server")"
        case .threads(let id): "threads-\(id)"
        case .user(let id): "user-\(id)"
        case .media(let item): "media-\(item.url.absoluteString)"
        case .members: "members"
        case .servers: "servers"
        case .reactions(_, let message, _): "reactions-\(message)"
        case .emojiPicker(_, let message): "emoji-\(message)"
        }
    }

    /// Lookups that open on the sidebar page at regular width (see `AppModel.present`).
    var opensInSidebar: Bool {
        switch self {
        case .friends, .search, .pins, .inbox, .settings, .threads, .reactions, .emojiPicker, .notifications: true
        case .user, .media, .members, .servers: false
        }
    }
}

/// The app's long-lived state. Survives every view rebuild, so folding,
/// rotating or changing size class never loses the selection, scroll
/// position, drafts or call.
@Observable
final class AppModel {
    enum Phase: Equatable { case loading, riskNotice, signedOut, signedIn }

    private(set) var phase: Phase = .loading {
        didSet { if phase != .signedIn { resetPresentations() } }
    }
    let store: DiscordStore
    let messages = MessageCenter()
    let settings = AppSettings()
    let fold = FoldState()
    private(set) var api: DiscordAPI = OfflineAPI()
    private(set) var gatewayStatus: GatewayStatus = .disconnected
    private(set) var isMock = false

    // Navigation
    let people = PeopleOperations()
    @ObservationIgnored var navigationIntent = UUID()
    @ObservationIgnored private let injectedMock: MockDiscord?
    @ObservationIgnored private let injectedMockWrites: Bool
    var selectedGuild: Snowflake? {
        didSet { cancelPendingSidebarTransfer(); navigationIntent = UUID() }
    }
    var selectedChannel: Snowflake? {
        didSet {
            cancelPendingSidebarTransfer()
            navigationIntent = UUID()
            if oldValue != selectedChannel {
                conversationVisit = UUID()
                composerContinuity.conversationChanged()
                if let oldValue {
                    ackTasks[oldValue]?.cancel()
                    store.resumeAutomaticReading(oldValue)
                    unreadMarkers[oldValue] = nil
                    unreadTargets[oldValue] = nil
                    automaticReadCeilings[oldValue] = nil
                }
                if let selectedChannel { store.resumeAutomaticReading(selectedChannel) }
            }
        }
    }
    var columnVisibility: NavigationSplitViewVisibility = .all
    var membersVisible = false {
        didSet {
            if oldValue != membersVisible {
                if !transferringPresentation { cancelPendingSidebarTransfer() }
                navigationIntent = UUID()
            }
        }
    }
    var sheet: AppSheet? {
        didSet {
            guard oldValue != sheet else { return }
            navigationIntent = UUID()
            if sheet != nil {
                sheetGeneration = UUID()
                // A replacement owns a new lifetime; its stale predecessor's
                // completion cannot finish a barrier for this generation.
                awaitingSheetDismissal = nil
            }
            guard !transferringPresentation else { return }
            if sheet != nil {
                // Explicit replacement wins over a lookup waiting behind a modal.
                cancelPendingSidebarTransfer()
            } else if oldValue != nil {
                awaitingSheetDismissal = sheetGeneration
            }
        }
    }
    /// Also owns a pending lookup while an unrelated modal has priority.
    /// Never copy that lookup into a second stored route.
    var sidebarPanel: AppSheet? {
        didSet {
            guard oldValue != sidebarPanel else { return }
            navigationIntent = UUID()
            guard !transferringPresentation else { return }
            pendingSidebarTransfer = false
            reconcileLookupPresentation()
        }
    }
    @ObservationIgnored private var transferringPresentation = false
    @ObservationIgnored private var pendingSidebarTransfer = false
    // Observed because MainView must refresh the generation-bound closures even
    // when an explicit presentation keeps an equal AppSheet value.
    private var sheetGeneration = UUID()
    @ObservationIgnored private var awaitingSheetDismissal: UUID?

    func present(_ lookup: AppSheet) {
        navigationIntent = UUID()
        cancelPendingSidebarTransfer()
        // Compact width, table-top, and non-sidebar routes use a sheet.
        if fold.isCompact || isTableTop || !lookup.opensInSidebar {
            // Even an equal explicit reopening is a new presentation intent.
            sheetGeneration = UUID()
            sheet = lookup
        } else {
            membersVisible = false
            sidebarPanel = sidebarPanel == lookup ? nil : lookup
            if sidebarPanel != nil, columnVisibility == .detailOnly { columnVisibility = .all }
        }
    }

    /// A binding belongs to one presentation generation, including routes with
    /// equal AppSheet IDs (for example two reaction tabs on the same message).
    var sheetBinding: Binding<AppSheet?> {
        let generation = sheetGeneration
        return Binding(get: { self.sheet }, set: { value in
            guard self.sheetGeneration == generation else { return }
            self.sheet = value
        })
    }

    /// Capture alongside the binding in MainView. Keep the generation through
    /// nil so a normal binding reset followed by onDismiss remains paired.
    var sheetDismissal: () -> Void {
        let generation = sheetGeneration
        return { self.sheetDidDismiss(generation: generation) }
    }

    // Deterministic completion of an already-started dismissal (also useful to
    // offline callers). It cannot dismiss a newer sheet by itself.
    func sheetDidDismiss() {
        guard let generation = awaitingSheetDismissal else { return }
        sheetDidDismiss(generation: generation)
    }

    private func sheetDidDismiss(generation: UUID) {
        guard generation == sheetGeneration else { return }
        // Handle either ordering of SwiftUI's binding reset and onDismiss.
        if sheet != nil { sheet = nil }
        guard awaitingSheetDismissal == generation else { return }
        awaitingSheetDismissal = nil
        reconcileLookupPresentation()
    }

    func resetPresentations() {
        pendingSidebarTransfer = false
        awaitingSheetDismissal = nil
        sheetGeneration = UUID()
        transferPresentation {
            sheet = nil
            sidebarPanel = nil
        }
    }

    private func cancelPendingSidebarTransfer() {
        guard pendingSidebarTransfer else { return }
        pendingSidebarTransfer = false
        transferPresentation { sidebarPanel = nil }
    }

    private func transferPresentation(_ update: () -> Void) {
        let wasTransferring = transferringPresentation
        transferringPresentation = true
        defer { transferringPresentation = wasTransferring }
        update()
    }

    private func reconcileLookupPresentation() {
        if fold.isCompact || isTableTop {
            guard let panel = sidebarPanel, panel.opensInSidebar else { return }
            // The current modal and its dismissal animation keep priority.
            guard sheet == nil, awaitingSheetDismissal == nil else {
                pendingSidebarTransfer = true
                return
            }
            pendingSidebarTransfer = false
            transferPresentation {
                sidebarPanel = nil
                sheet = panel
            }
        } else {
            pendingSidebarTransfer = false
            // A pre-existing sidebar route means this is an unrelated modal,
            // not the compact representation of that route. Keep both owners.
            guard sidebarPanel == nil, let open = sheet, open.opensInSidebar else { return }
            transferPresentation {
                sheet = nil
                membersVisible = false
                sidebarPanel = open
            }
            if columnVisibility == .detailOnly { columnVisibility = .all }
        }
    }

    var isTableTop: Bool {
        if case .tableTop = fold.posture, !fold.isCompact { return true }
        return false
    }

    func toggleMembers() {
        if fold.isCompact || isTableTop {
            sheet = .members
            return
        }
        sidebarPanel = nil
        membersVisible.toggle()
        if membersVisible, columnVisibility == .detailOnly { columnVisibility = .all }
    }
    var expandedFolders: Set<Int64> = []
    @ObservationIgnored private var lastChannelByGuild: [Snowflake: Snowflake] = [:]
    @ObservationIgnored private var lastSelectedChannel: Snowflake?

    // Per-channel state that must survive view rebuilds.
    var drafts: [Snowflake: Draft] = [:]
    @ObservationIgnored var anchors: [Snowflake: ScrollAnchor] = [:]
    var unreadMarkers: [Snowflake: Snowflake] = [:]
    var unreadTargets: [Snowflake: Snowflake] = [:]
    /// Requests the visible list to scroll to a message.
    var revealRequest: (channel: Snowflake, message: Snowflake, token: UUID)?
    /// The open conversation is scrolled away from its newest message.
    var viewingHistory = false
    /// The software keyboard is on screen (the side bar is shorter).
    var keyboardVisible = false
    /// Asks the list for this channel to jump to its newest message (consumed once).
    var jumpRequest: (channel: Snowflake, token: UUID)?
    let composerContinuity = ComposerContinuity()
    /// Whether replies ping their author ("@ On" in the reply banner). Kept
    /// for the session, as Discord does.
    var pingReplies = true
    /// The error near the composer, if one is showing.
    private(set) var toast: Toast?
    /// The draft set aside while editing a message; Cancel or Save puts it back.
    @ObservationIgnored private var stashedDrafts: [Snowflake: Draft] = [:]

    @ObservationIgnored private var gateway: GatewayConnection?
    @ObservationIgnored private var hadReady = false
    /// Everything needed to resend a message, kept per nonce until it is confirmed.
    @ObservationIgnored private var outgoing: [String: (text: String, reply: Message?, ping: Bool, files: [DraftAttachment])] = [:]
    @ObservationIgnored private var gatewayTask: Task<Void, Never>?
    @ObservationIgnored private var ackTasks: [Snowflake: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastTyping: [Snowflake: Date] = [:]
    @ObservationIgnored private var memberQueries: Set<String> = []
    @ObservationIgnored private var memberSearch: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.saphid.duocord.native", category: "app")
    @ObservationIgnored let voice: VoiceController
    @ObservationIgnored let notifications: NotificationService
    @ObservationIgnored let keepAlive = BackgroundKeepAlive()
    @ObservationIgnored private(set) var credentials: SessionCredentials?
    @ObservationIgnored var isActive = true

    /// Only concrete MockDiscord injection authorizes DEBUG writes. A mock
    /// injection is retained by start() and cannot become a live sign-in.
    init(notificationAPI: DiscordAPI? = nil, store: DiscordStore? = nil, readAPI: MockDiscord? = nil, peopleAPI: MockDiscord? = nil, notifications: NotificationService = .shared) {
        self.notifications = notifications
        self.store = store ?? DiscordStore()
        injectedMock = peopleAPI ?? readAPI ?? (notificationAPI as? MockDiscord)
        injectedMockWrites = peopleAPI != nil || readAPI != nil
        if let notificationAPI { api = notificationAPI }
        if let injectedMock { api = injectedMock; isMock = injectedMockWrites }
        voice = VoiceController()
        voice.model = self
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardVisible = true }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardVisible = false }
        }
        self.store.onMessageCreate = { [weak self] message in self?.received(message) }
        self.store.onPeopleReset = { [weak self] in self?.people.reset() }
        self.store.onPrivacyChange = { [weak self] in self?.messages.invalidatePrivacy() }
        self.store.onAcceptedRead = { [weak self] channel, boundary in
            guard let self else { return }
            self.notifications.clear(channel: channel, through: boundary, store: self.store)
        }
        self.store.onReadReset = { [weak self] in
            self?.readResets &+= 1
            self?.cancelReadOperations()
            self?.ackTasks.values.forEach { $0.cancel() }
            self?.ackTasks = [:]
            self?.unreadMarkers = [:]
        }
    }

    private(set) var notificationSaves: [Snowflake: Int] = [:]
    private(set) var notificationErrors: [Snowflake: String] = [:]
    @ObservationIgnored private var notificationWrites: [Snowflake: Task<Void, Never>] = [:]
    @ObservationIgnored private var notificationSession = UUID()

    /// Confirmed updates only. Serialize the entire guild resource, including
    /// its channel overrides, so HTTP responses cannot reorder local choices.
    @discardableResult
    func changeNotifications(_ target: NotificationTarget, patch: NotificationPatch) -> Task<Void, Never> {
        let resource = target.resource
        let previous = notificationWrites[resource]
        let session = notificationSession
        let api = api
        notificationSaves[resource, default: 0] += 1
        notificationErrors[resource] = nil
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.notificationSession == session, !Task.isCancelled else { return }
            self.notificationErrors[resource] = nil
            let versions = self.store.notificationVersions(for: resource)
            let requested = Set(GuildSettingsUpdate(fields: patch.fields(for: target)).leaves.keys)
            do {
                let result = try await api.patchNotificationSettings(target: target, patch: patch)
                guard self.notificationSession == session else { return }
                try self.store.applyNotificationSettings(result, resource: resource, requested: requested, versions: versions)
            } catch {
                guard self.notificationSession == session else { return }
                self.notificationErrors[resource] = error.localizedDescription
                self.showError("Couldn’t save notification settings. " + error.localizedDescription)
            }
            self.notificationSaves[resource, default: 1] -= 1
            if self.notificationSaves[resource] == 0 { self.notificationWrites[resource] = nil }
            self.updateBadge()
        }
        notificationWrites[resource] = task
        return task
    }

    func muteNotifications(_ target: NotificationTarget, for duration: MuteDuration?) {
        changeNotifications(target, patch: .mute(duration, now: store.notificationNow))
    }

    private func cancelNotificationWrites() {
        notificationSession = UUID()
        notificationWrites.values.forEach { $0.cancel() }
        notificationWrites = [:]
        notificationSaves = [:]
        notificationErrors = [:]
    }

    // MARK: Lifecycle

    func start() {
        if injectedMock != nil { startMock(); return }
        Perf.shared.markOnce("appStart")
        if let provision = LoginStore.importProvisioningFile(), provision.acknowledgeRisk == true {
            settings.acknowledgedRisk = true
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "DuocordResetSession") { SessionStore.clear() }
        // Screenshots of the first-run screens without touching the session.
        if let screen = UserDefaults.standard.string(forKey: "DuocordShowScreen") {
            phase = screen == "risk" ? .riskNotice : .signedOut
            return
        }
        if UserDefaults.standard.bool(forKey: "DuocordMock") {
            startMock()
            return
        }
        #endif
        if !settings.acknowledgedRisk {
            phase = .riskNotice
            return
        }
        if let saved = SessionStore.load() {
            signIn(with: saved, persist: false)
        } else {
            phase = .signedOut
        }
    }

    func acknowledgeRisk() {
        settings.acknowledgedRisk = true
        start()
    }

    func signIn(with credentials: SessionCredentials, persist: Bool = true) {
        guard injectedMock == nil else { return }
        beginAccountGeneration()
        store.reset()
        messages.reset()
        if persist { SessionStore.save(credentials) }
        self.credentials = credentials
        api = DiscordREST(credentials: credentials)
        restoreNavigation()
        // Last session's servers and conversation, drawn before the gateway connects.
        if !persist, let snapshot = SnapshotCache.loadSnapshot(), snapshot.me.id.raw != 0 {
            store.apply(snapshot: snapshot)
            if let channel = selectedChannel, let cached = SnapshotCache.loadMessages(channel: channel) {
                store.remember(messageAuthors: cached)
                timeline(for: channel).seed(cached)
            }
            Perf.shared.markOnce("snapshotApplied", extra: ["channels": snapshot.channels.count])
        }
        let gateway = LiveGateway(credentials: credentials)
        connect(gateway)
        phase = .signedIn
        notifications.requestAuthorizationIfNeeded()
        reconcileKeepAlive()
    }

    func signOut() {
        beginAccountGeneration()
        gatewayTask?.cancel()
        ackTasks.values.forEach { $0.cancel() }
        ackTasks = [:]
        let gateway = self.gateway
        Task { await gateway?.disconnect() }
        self.gateway = nil
        voice.leave()
        SessionStore.clear()
        SnapshotCache.clear()
        credentials = nil
        store.reset()
        messages.reset()
        drafts = [:]
        composerContinuity.reset()
        anchors = [:]
        selectedChannel = nil
        selectedGuild = nil
        cancelNotificationWrites()
        cancelReadOperations()
        unreadMarkers = [:]
        api = OfflineAPI()
        phase = .signedOut
        keepAlive.stop()
        notifications.setBadge(0)
    }

    private func startMock() {
        isMock = injectedMock == nil || injectedMockWrites
        beginAccountGeneration()
        let mock = injectedMock ?? MockDiscord()
        api = mock
        connect(MockGateway(data: mock))
        phase = .signedIn
        restoreNavigation()
        notifications.requestAuthorizationIfNeeded()
    }

    private func connect(_ gateway: GatewayConnection) {
        self.gateway = gateway
        gatewayTask?.cancel()
        gatewayTask = Task { [weak self] in
            await gateway.connect()
            for await event in gateway.events {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .status(let status):
                    self.gatewayStatus = status
                    if case .failed(let reason) = status, reason == "unauthorized" { self.sessionExpired() }
                case .dispatch(let dispatch):
                    await self.handle(dispatch)
                }
            }
        }
    }

    private func sessionExpired() {
        log.notice("session expired")
        signOut()
    }

    func handle(_ dispatch: GatewayDispatch) async {
        switch dispatch.name {
        case "MOCK_READY":
            guard let mock = api as? MockDiscord else { return }
            store.apply(ready: mock.readyPayload())
            readyApplied()
            Perf.shared.markOnce("ready", extra: ["mock": true])
            validateSelection()
            subscribeVisibleGuild()
        case "READY":
            let session = readSession
            let state = Perf.signposter.beginInterval("ready decode")
            let ready = await Task.detached(priority: .userInitiated) { try? dispatch.decode(ReadyPayload.self) }.value
            Perf.signposter.endInterval("ready decode", state)
            guard readSession == session else { return }
            guard let ready else {
                log.error("READY failed to decode")
                return
            }
            let reconnect = hadReady
            hadReady = true
            store.apply(ready: ready)
            readyApplied()
            Perf.shared.markOnce("ready", extra: ["guilds": ready.guilds.count])
            if reconnect {
                // A new session, not a resume: events may have been missed.
                messages.markAllNeedRefresh()
                if let channel = selectedChannel { Task { await timeline(for: channel).loadLatest(api: api, store: store) } }
            }
            saveCache()
            validateSelection()
            subscribeVisibleGuild()
            updateBadge()
        case "MESSAGE_CREATE":
            store.handle(dispatch)
        case "MESSAGE_DELETE":
            store.handle(dispatch)
            if let deleted = try? dispatch.decode(MessageDelete.self) {
                unreadTargetDeleted(channel: deleted.channelID, ids: [deleted.id])
            }
            messages.handle(dispatch, me: store.me?.id)
        case "MESSAGE_DELETE_BULK":
            store.handle(dispatch)
            if let deleted = try? dispatch.decode(MessageDeleteBulk.self) {
                unreadTargetDeleted(channel: deleted.channelID, ids: Set(deleted.ids))
            }
            messages.handle(dispatch, me: store.me?.id)
        case "MESSAGE_UPDATE":
            store.handle(dispatch)
            messages.handle(dispatch, me: store.me?.id)
        case "MESSAGE_REACTION_ADD", "MESSAGE_REACTION_REMOVE",
             "MESSAGE_REACTION_REMOVE_ALL", "MESSAGE_REACTION_REMOVE_EMOJI", "MESSAGE_POLL_VOTE_ADD", "MESSAGE_POLL_VOTE_REMOVE":
            messages.handle(dispatch, me: store.me?.id)
        case "VOICE_STATE_UPDATE":
            store.handle(dispatch)
            voice.stateChanged()
        case "MESSAGE_ACK":
            let held = store.manualUnreadChannels
            store.handle(dispatch)
            for channel in held.subtracting(store.manualUnreadChannels) {
                unreadMarkers[channel] = nil
                unreadTargets[channel] = nil
                automaticReadCeilings[channel] = nil
            }
            updateBadge()
        default:
            store.handle(dispatch)
            if dispatch.name == "MESSAGE_ACK" || dispatch.name == "CHANNEL_UNREAD_UPDATE" { updateBadge() }
        }
    }

    private func received(_ message: Message) {
        messages.received(message)
        let visible = isActive && message.channelID == selectedChannel
        if !visible, settings.notificationsEnabled, store.shouldNotify(message) {
            notifications.post(message: message, store: store)
        }
        updateBadge()
    }

    func updateBadge() {
        notifications.setBadge(settings.badgeEnabled ? store.totalBadge : 0)
    }

    // MARK: Navigation

    var isHome: Bool { selectedGuild == nil }

    /// A server rail tap (a server, or Home for direct messages) asks for
    /// that destination's list. The Members page takes the list's place in
    /// the sidebar, so it steps aside rather than hide the list.
    func openFromRail(guild: Snowflake?) {
        membersVisible = false
        select(guild: guild)
    }

    func select(guild: Snowflake?) {
        navigationIntent = UUID()
        selectedGuild = guild
        if let guild {
            let remembered = lastChannelByGuild[guild].flatMap { store.channel($0) }
            let first = store.sections(for: guild).flatMap(\.channels).first {
                !$0.type.isThread && (($0.type.isTextLike && !$0.type.isVoice) || $0.type.isForumLike)
            }
            if let channel = remembered ?? first, UIDevice.current.userInterfaceIdiom == .pad || !fold.isCompact {
                select(channel: channel.id)
            }
            subscribeVisibleGuild()
        }
        saveNavigation()
    }

    func select(channel: Snowflake?) {
        navigationIntent = UUID()
        guard let channel else {
            selectedChannel = nil
            store.visibleChannel = nil
            return
        }
        if let info = store.channel(channel), store.isUnresolvedThread(info) {
            resolveParentAndSelect(info, intent: navigationIntent)
            return
        }
        Perf.shared.begin("channelSwitch")
        if sheet == .servers { sheet = nil }
        if let previous = selectedChannel, previous != channel, !isMock, let timeline = messages.existingTimeline(for: previous), timeline.isAtLatest {
            SnapshotCache.save(messages: timeline.messages.filter { timeline.sendState(for: $0) == nil }, channel: previous)
        }
        if let info = store.channel(channel) {
            if let guild = info.guildID {
                if selectedGuild != guild { selectedGuild = guild }
                lastChannelByGuild[guild] = channel
            } else {
                selectedGuild = nil
            }
        }
        if unreadMarkers[channel] == nil, let info = store.channel(channel), store.isUnread(info) {
            unreadMarkers[channel] = store.readBoundary(info)
        }
        selectedChannel = channel
        lastSelectedChannel = channel
        store.visibleChannel = channel
        store.visibleIsLive = false
        viewingHistory = false
        subscribeVisibleGuild()
        saveNavigation()
    }

    /// A fallback thread row carries activity, but cannot imply permission to
    /// read a missing parent's history. Resolve it before changing selection.
    @discardableResult
    func resolveParentAndSelect(_ thread: Channel, intent: UUID, message: Snowflake? = nil) -> Task<Void, Never> {
        let epoch = store.readEpoch, api = api
        guard let parentID = thread.parentID else {
            showError("This thread's parent channel is unavailable.")
            return Task {}
        }
        let revision = store.channelRevision
        return Task { [weak self] in
            do {
                let parent = try await api.channel(parentID)
                guard let self, self.store.readEpoch == epoch, self.navigationIntent == intent,
                      ObjectIdentifier(self.api as AnyObject) == ObjectIdentifier(api as AnyObject),
                      self.store.channel(thread.id)?.parentID == parentID else { return }
                guard parent.id == parentID, parent.guildID == thread.guildID, !parent.type.isThread else {
                    self.showError("This thread's parent channel could not be verified.")
                    return
                }
                if !self.store.channelChanged(parentID, since: revision) { self.store.upsert(channel: parent) }
                guard let current = self.store.channel(thread.id), !self.store.isUnresolvedThread(current), self.store.canView(current) else {
                    self.showError("You can't view this thread's parent channel.")
                    return
                }
                self.select(channel: thread.id)
                if let message { self.revealRequest = (thread.id, message, UUID()) }
            } catch {
                guard let self, self.store.readEpoch == epoch, self.navigationIntent == intent else { return }
                self.showError("Couldn't load this thread's parent channel. " + error.localizedDescription)
            }
        }
    }

    /// Unfolding to regular width with nothing open restores the last
    /// conversation, so going back to the list on the outer display never
    /// loses the place.
    func sizeClassChanged(compact: Bool) {
        reconcileLookupPresentation()
        if !compact, selectedChannel == nil, let last = lastSelectedChannel, store.channel(last) != nil {
            select(channel: last)
        }
    }

    /// Jumps to a message anywhere (search, inbox, pins, notifications, links).
    func open(channel: Snowflake, message: Snowflake?) {
        sheet = nil
        // Inbox and search panels stay open beside the conversation; others close.
        if let panel = sidebarPanel, panel != .search, panel != .inbox { sidebarPanel = nil }
        if let info = store.channel(channel), store.isUnresolvedThread(info) {
            navigationIntent = UUID()
            resolveParentAndSelect(info, intent: navigationIntent, message: message)
        } else {
            select(channel: channel)
            if let message { revealRequest = (channel, message, UUID()) }
        }
    }

    private func validateSelection() {
        if let channel = selectedChannel, store.channel(channel) == nil {
            selectedChannel = nil
        }
        if let guild = selectedGuild, store.guilds[guild] == nil { selectedGuild = nil }
        if selectedChannel == nil, let guild = selectedGuild { select(guild: guild) }
    }

    private func subscribeVisibleGuild() {
        guard let guild = selectedGuild, let gateway else { return }
        let channel = selectedChannel.flatMap { store.channel($0) }.flatMap { $0.type.isThread ? $0.parentID : $0.id }
        Task { await gateway.subscribe(guild: guild, channel: channel, ranges: [[0, 99]]) }
    }

    private func saveNavigation() {
        UserDefaults.standard.set(selectedGuild?.description, forKey: "nav.guild")
        UserDefaults.standard.set(selectedChannel?.description, forKey: "nav.channel")
    }

    private func restoreNavigation() {
        selectedGuild = UserDefaults.standard.string(forKey: "nav.guild").flatMap(Snowflake.init)
        if let channel = UserDefaults.standard.string(forKey: "nav.channel").flatMap(Snowflake.init) {
            selectedChannel = channel
            store.visibleChannel = channel
        }
        #if DEBUG
        // Automation overrides; "0" clears the selection.
        if let raw = UserDefaults.standard.string(forKey: "DuocordOpenChannel"), let channel = Snowflake(raw) {
            selectedChannel = channel.raw == 0 ? nil : channel
            store.visibleChannel = selectedChannel
        }
        if let raw = UserDefaults.standard.string(forKey: "DuocordOpenGuild"), let guild = Snowflake(raw) {
            selectedGuild = guild.raw == 0 ? nil : guild
        }
        #endif
    }

    func timeline(for channel: Snowflake) -> MessageTimeline { messages.timeline(for: channel) }

    /// Snapshot plus the open conversation's newest page, for the next cold start.
    func saveCache() {
        guard !isMock, let snapshot = store.snapshot() else { return }
        SnapshotCache.save(snapshot)
        Perf.shared.record("saveCache", ["channel": selectedChannel?.description ?? "-", "timeline": messages.existingTimeline(for: selectedChannel ?? 0) != nil])
        if let channel = selectedChannel, let timeline = messages.existingTimeline(for: channel), timeline.isAtLatest {
            SnapshotCache.save(messages: timeline.messages.filter { timeline.sendState(for: $0) == nil }, channel: channel)
        }
    }

    // MARK: Reading

    func didRead(channel: Snowflake, upTo message: Snowflake) {
        guard isActive, channel == selectedChannel,
              !store.manualUnreadChannels.contains(channel), !store.pendingUnreadChannels.contains(channel),
              readSaves[channel, default: 0] == 0,
              automaticReadCeilings[channel].map({ message <= $0 }) ?? true else { return }
        let state = store.readStates[channel]
        guard (state?.lastMessageID ?? 0) < message || (state?.mentionCount ?? 0) > 0 else { return }
        store.markRead(channel, upTo: message)
        updateBadge()
        guard settings.markReadOnServer, allowsReadWrites else { return }
        ackTasks[channel]?.cancel()
        let epoch = store.readEpoch
        ackTasks[channel] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard !Task.isCancelled, let self, self.store.readEpoch == epoch, self.isActive,
                  self.settings.markReadOnServer, self.selectedChannel == channel,
                  !self.store.manualUnreadChannels.contains(channel), !self.store.pendingUnreadChannels.contains(channel) else { return }
            await self.enqueueRead([ReadAcknowledgement(channel: channel, message: message)], automatic: true).value
        }
    }

    func cancelAutomaticAck(_ channel: Snowflake) {
        ackTasks[channel]?.cancel()
        ackTasks[channel] = nil
    }

    @ObservationIgnored var automaticReadCeilings: [Snowflake: Snowflake] = [:]
    var readSaves: [Snowflake: Int] = [:]
    var readErrors: [Snowflake: String] = [:]
    @ObservationIgnored var readQueue: Task<Void, Never>?
    @ObservationIgnored var readSession = UUID()
    @ObservationIgnored var unreadTargetOperations: [UUID: UnreadTargetOperation] = [:]
    @ObservationIgnored var conversationVisit = UUID()
    /// Changes with every sign-in, sign-out and mock start; fences alert actions.
    @ObservationIgnored private(set) var accountGeneration = UUID()
    @ObservationIgnored private var readResets = 0
    @ObservationIgnored private var readyResetMark: Int?
    @ObservationIgnored private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// How long a cold-launched alert action waits for READY.
    @ObservationIgnored var notificationReadyTimeout: Duration = .seconds(15)
    /// Last first-visible message, reported by the list without changing its anchor.
    var firstVisibleMessages: [Snowflake: Snowflake] = [:]

    // MARK: Composer

    func userTyped(in channel: Snowflake) {
        guard settings.sendTypingIndicator, !isMock else { return }
        if let last = lastTyping[channel], Date.now.timeIntervalSince(last) < 8 { return }
        lastTyping[channel] = .now
        Task { [api] in try? await api.typing(channel: channel) }
    }

    func send(in channel: Snowflake, pingReply: Bool? = nil) {
        guard let draft = drafts[channel] else { return }
        if draft.editing != nil { return saveEdit(in: channel) }
        let text = outgoingText(draft, in: channel)
        guard !text.isEmpty || !draft.attachments.isEmpty, let me = store.me else { return }
        enqueueSend(text, in: channel, author: me, replyTo: draft.replyTo, ping: pingReply ?? pingReplies, files: draft.attachments)
        drafts[channel] = Draft()
        lastTyping[channel] = nil
    }

    /// The pending echo, nonce, confirm and failure path shared by the composer
    /// and alert replies. With `authority`, `start` is checked just before the
    /// request and `result` before its outcome changes anything. The task
    /// yields true when confirmed, false when failed, nil when not adopted.
    @discardableResult
    private func enqueueSend(_ text: String, in channel: Snowflake, author me: User, replyTo: Message?, ping: Bool,
                             files attachments: [DraftAttachment],
                             authority: (start: () -> Bool, result: () -> Bool)? = nil) -> Task<Bool?, Never> {
        let nonce = String(Snowflake.at(.now).raw + UInt64.random(in: 0..<4096))
        let timeline = timeline(for: channel)
        var echo = Message(id: Snowflake(UInt64(nonce) ?? 0), channelID: channel, guildID: store.channel(channel)?.guildID,
                           author: me, content: text, timestamp: ISO8601DateFormatter().string(from: .now),
                           referencedMessage: replyTo)
        echo.nonce = nonce
        if replyTo != nil { echo.type = 19 }
        echo.attachments = attachments.enumerated().map { index, file in
            Attachment(id: Snowflake(UInt64(index)), filename: file.filename, size: file.data.count, url: "about:blank",
                       proxyURL: nil, width: nil, height: nil, contentType: file.contentType, description: nil, flags: nil, durationSecs: nil)
        }
        timeline.addPending(echo)
        outgoing[nonce] = (text, replyTo, ping, attachments)
        let reply = replyTo?.id
        let files = attachments.map { OutgoingAttachment(filename: $0.filename, data: $0.data, contentType: $0.contentType) }
        return Task { [api] in
            if let authority, Task.isCancelled || !authority.start() {
                // Never sent. Only a still-current login removes its echo.
                if authority.result() {
                    self.outgoing[nonce] = nil
                    timeline.discardPending(nonce: nonce)
                }
                return nil
            }
            do {
                let sent = try await api.send(channel: channel, content: text, replyTo: reply, pingReply: ping, attachments: files, nonce: nonce)
                if let authority, !authority.result() { return nil }
                timeline.confirm(nonce: nonce, with: sent)
                self.outgoing[nonce] = nil
                return true
            } catch {
                if let authority, !authority.result() { return nil }
                timeline.markFailed(nonce: nonce, error: error.localizedDescription)
                return false
            }
        }
    }

    /// Resends exactly what failed (text, reply, ping and attachments),
    /// leaving whatever is in the composer now untouched.
    func retry(_ message: Message) {
        guard let nonce = message.nonce, let payload = outgoing.removeValue(forKey: nonce) else { return }
        let channel = message.channelID
        timeline(for: channel).discardPending(nonce: nonce)
        let current = drafts[channel]
        drafts[channel] = Draft(text: payload.text, replyTo: payload.reply, attachments: payload.files)
        send(in: channel, pingReply: payload.ping)
        drafts[channel] = current
    }

    /// Drops a send that failed (or is still pending); nothing reaches Discord.
    func discard(_ message: Message) {
        guard let nonce = message.nonce else { return }
        outgoing[nonce] = nil
        timeline(for: message.channelID).discardPending(nonce: nonce)
    }

    // MARK: Alert actions

    /// Routes this service's Reply and Mark as Read (the app does this once
    /// for the shared service, beside its tap handler).
    func connectAlertActions(_ service: NotificationService) {
        service.onAction = { [weak self] action, origin in
            await self?.performAlertAction(action, origin: origin) ?? .refused
        }
    }

    /// One login attempt, account and store state. Any later READY, store
    /// reset, sign-in or sign-out changes it.
    private struct AlertAuthority: Equatable {
        let generation: UUID
        let account: Snowflake
        let resets: Int
    }

    private var currentAlertAuthority: AlertAuthority? {
        guard store.isReady, let me = store.me else { return nil }
        return AlertAuthority(generation: accountGeneration, account: me.id, resets: readResets)
    }

    private func beginAccountGeneration() {
        accountGeneration = UUID()
        let waiters = readyWaiters
        readyWaiters = [:]
        waiters.values.forEach { $0.resume(returning: false) }
    }

    private func readyApplied() {
        readyResetMark = readResets
        let waiters = readyWaiters
        readyWaiters = [:]
        waiters.values.forEach { $0.resume(returning: true) }
    }

    /// Ready now, or (cold launch) only this login attempt's first READY within
    /// the bound: exactly one reset since waiting, and it was that READY's.
    private func alertAuthority(for account: Snowflake) async -> AlertAuthority? {
        guard !Task.isCancelled else { return nil }
        if let authority = currentAlertAuthority { return authority.account == account ? authority : nil }
        guard phase == .loading || phase == .signedIn else { return nil }
        let generation = accountGeneration, resets = readResets
        guard await waitForReady(), !Task.isCancelled, accountGeneration == generation, readResets == resets &+ 1,
              readyResetMark == readResets, let authority = currentAlertAuthority, authority.account == account else { return nil }
        return authority
    }

    private func waitForReady() async -> Bool {
        let id = UUID(), timeout = notificationReadyTimeout
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.finishReadyWait(id, ready: false)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) } else { readyWaiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishReadyWait(id, ready: false) }
        }
    }

    private func finishReadyWait(_ id: UUID, ready: Bool) {
        readyWaiters.removeValue(forKey: id)?.resume(returning: ready)
    }

    /// Reply sends trimmed text as a plain message through the normal pending
    /// path; Mark as Read acknowledges through the notified message. Neither
    /// reads or changes a draft, reply target, edit, stash or focus.
    func performAlertAction(_ action: NotificationActionResponse.Action, origin: LocalAlertOrigin) async -> NotificationActionOutcome {
        if case .reply(let text) = action, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .unchanged }
        guard let authority = await alertAuthority(for: origin.account), !Task.isCancelled,
              store.channel(origin.channel) != nil else { return .refused }
        switch action {
        case .reply(let text):
            guard let me = store.me, NotificationService.canQuickReply(in: store.channel(origin.channel), store: store) else { return .refused }
            let current = { [weak self] in
                guard let self, self.currentAlertAuthority == authority else { return false }
                return NotificationService.canQuickReply(in: self.store.channel(origin.channel), store: self.store)
            }
            let sameLogin = { [weak self] in self?.accountGeneration == authority.generation && self?.store.me?.id == authority.account }
            let sent = enqueueSend(text.trimmingCharacters(in: .whitespacesAndNewlines), in: origin.channel, author: me, replyTo: nil,
                                   ping: pingReplies, files: [], authority: (start: current, result: sameLogin))
            let result = await withTaskCancellationHandler {
                await sent.value
            } onCancel: {
                sent.cancel()
            }
            switch result {
            case true?: return .sent
            case false?: return .sendFailed
            case nil: return .refused
            }
        case .markRead:
            guard let read = markAsRead(channel: origin.channel, through: origin.message) else { return .unchanged }
            await withTaskCancellationHandler {
                await read.value
            } onCancel: {
                read.cancel()
            }
            guard !Task.isCancelled else { return .refused }
            return currentAlertAuthority == authority && readErrors[origin.channel] == nil ? .markedRead : .readFailed
        case .open, .ignore:
            return .ignored
        }
    }

    // MARK: Your messages

    /// Starts a reply to `message` and puts the cursor in the composer.
    func reply(to message: Message) {
        let channel = message.channelID
        var draft = drafts[channel] ?? Draft()
        // Replying leaves edit mode, as in Discord.
        if draft.editing != nil { draft = stashedDrafts.removeValue(forKey: channel) ?? Draft() }
        draft.replyTo = message
        drafts[channel] = draft
        composerContinuity.requestFocus(in: channel)
    }

    /// The composer switches to editing `message`: its text is filled in
    /// and whatever was being written is set aside until Cancel or Save.
    func beginEdit(_ message: Message) {
        guard message.author.id == store.me?.id else { return }
        let channel = message.channelID
        let current = drafts[channel] ?? Draft()
        if current.editing == nil { stashedDrafts[channel] = current }
        // Mentions, channels and emoji read as they do in the list; saving converts them back.
        let guild = message.guildID ?? store.channel(channel)?.guildID
        let readable = Autocomplete.readable(message.content,
                                             user: { [store] id in store.users[id].map { store.displayName(for: $0, in: guild) } },
                                             role: { [store] id in store.role(id, in: guild)?.name },
                                             channel: { [store] id in store.channel(id)?.name })
        drafts[channel] = Draft(text: readable.text, editing: message, tokens: readable.tokens)
        composerContinuity.requestFocus(in: channel)
    }

    func cancelEdit(in channel: Snowflake) {
        guard drafts[channel]?.editing != nil else { return }
        drafts[channel] = stashedDrafts.removeValue(forKey: channel) ?? Draft()
    }

    /// Saves the edit: shown at once, put back with an error if Discord
    /// refuses it. Unchanged text just leaves edit mode.
    func saveEdit(in channel: Snowflake) {
        guard let draft = drafts[channel], let message = draft.editing else { return }
        let text = outgoingText(draft, in: channel)
        guard !text.isEmpty else { return }
        cancelEdit(in: channel)
        guard let request = timeline(for: channel).sendEdit(message.id, content: text, api: api) else { return }
        Task {
            if await request.value == false { showError("Couldn't edit message") }
        }
    }

    /// Deletes one of your messages (after the list has confirmed it):
    /// removed at once, back in place with an error if Discord refuses it.
    func delete(_ message: Message) {
        let timeline = timeline(for: message.channelID)
        if timeline.sendState(for: message) != nil { return discard(message) }
        guard message.author.id == store.me?.id else { return }
        if drafts[message.channelID]?.editing?.id == message.id { cancelEdit(in: message.channelID) }
        guard let request = timeline.sendDelete(message.id, api: api) else { return }
        Task {
            if await request.value == false { showError("Couldn't delete message") }
        }
    }

    /// Only concrete mock sessions pin in DEBUG; a real account is refused
    /// before anything is shown or sent.
    var allowsPinWrites: Bool {
        #if DEBUG
        isMock && api is MockDiscord
        #else
        !(api is OfflineAPI)
        #endif
    }

    /// Pins or unpins (after the list's confirmation) the message as it is
    /// now in the window, not as the menu saw it: nothing happens when it is
    /// already that way. Shown at once; sent only if this login, store epoch
    /// and permission still hold when the request starts; put back with an
    /// error if Discord refuses it. Nil when nothing was started.
    @discardableResult
    func setPinned(_ pinned: Bool, message: Message) -> Task<Bool, Never>? {
        guard allowsPinWrites else {
            showError("Pinning is disabled for real accounts in Debug.")
            return nil
        }
        let id = message.id, channel = message.channelID
        guard let authority = currentAlertAuthority, let timeline = messages.existingTimeline(for: channel),
              let current = timeline.messages.first(where: { $0.id == id }),
              current.pinned != pinned, timeline.canChangePin(current, store: store) else { return nil }
        let api = api
        let sameLogin = { [weak self] in self?.accountGeneration == authority.generation && self?.store.me?.id == authority.account }
        return timeline.sendPin(id, pinned: pinned, api: api, start: { [weak self] in
            guard let self, self.currentAlertAuthority == authority, self.allowsPinWrites,
                  self.messages.existingTimeline(for: channel) === timeline,
                  let row = timeline.messages.first(where: { $0.id == id }) else { return false }
            return timeline.canChangePin(row, store: self.store)
        }, result: { [weak self] in self?.currentAlertAuthority == authority }, unwindUnsent: sameLogin, completion: { [weak self] applied in
            if !applied { self?.showError(pinned ? "Couldn't pin message" : "Couldn't unpin message") }
        })
    }

    // MARK: Autocomplete

    /// What Discord receives for a draft: autocomplete tokens in wire form,
    /// and typed `:shortcodes:` of this server's or standard emoji as emoji.
    func outgoingText(_ draft: Draft, in channel: Snowflake) -> String {
        let custom = store.channel(channel)?.guildID.flatMap { store.guilds[$0]?.emojis } ?? []
        let wired = Autocomplete.wireText(draft.text, tokens: draft.tokens)
        return Autocomplete.replacingShortcodes(in: wired) { name in
            if let emoji = custom.first(where: { $0.name == name }), let id = emoji.id {
                return "<\(emoji.animated == true ? "a" : ""):\(name):\(id)>"
            }
            return Autocomplete.standardEmoji[name]
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Suggestions for the word being typed in `channel`'s composer.
    func suggestions(for query: Autocomplete.Query, in channel: Channel) -> [Autocomplete.Suggestion] {
        switch query.trigger {
        case .mention:
            _ = store.memberSearchRevision // refresh when a member search answers
            let guild = channel.guildID
            var candidates: [Snowflake: Autocomplete.MentionCandidate] = [:]
            func add(_ user: User, recency: Int? = nil) {
                if var existing = candidates[user.id] {
                    if let recency, existing.recency == nil { existing.recency = recency; candidates[user.id] = existing }
                    return
                }
                candidates[user.id] = .init(user: user, name: store.displayName(for: user, in: guild),
                                            nick: store.member(user.id, in: guild)?.nick, recency: recency)
            }
            // Recent authors here, newest first.
            if let timeline = messages.existingTimeline(for: channel.id) {
                var seen = Set<Snowflake>()
                for message in timeline.messages.reversed() where seen.count < 30 && !message.isSystem {
                    if seen.insert(message.author.id).inserted { add(message.author, recency: seen.count - 1) }
                }
            }
            if let guild {
                for member in (store.members[guild] ?? [:]).values {
                    if let user = member.user ?? member.userID.flatMap({ store.users[$0] }) { add(user) }
                }
                if let me = store.me { add(me) }
            } else {
                store.recipients(of: channel).forEach { add($0) }
                if let me = store.me { add(me) }
            }
            return Autocomplete.mentionSuggestions(members: Array(candidates.values), roles: store.mentionableRoles(in: channel),
                                                   massMentions: store.canMentionEveryone(in: channel), query: query.text)
        case .emoji:
            let custom = channel.guildID.flatMap { store.guilds[$0]?.emojis } ?? []
            return Autocomplete.emojiSuggestions(custom: custom, unicode: Autocomplete.standardEntries,
                                                 recent: (settings.recentEmoji + EmojiPickerView.popular).map(\.reactionKey), query: query.text)
        case .channel:
            guard let guild = channel.guildID else { return [] }
            var list: [Channel] = []
            for section in store.sections(for: guild) {
                for item in section.channels where (item.type.isTextLike && !item.type.isVoice) || item.type.isForumLike {
                    list.append(item)
                    list += store.threads(in: item.id).filter { store.canView($0) }
                }
            }
            return Autocomplete.channelSuggestions(list, query: query.text)
        }
    }

    /// Puts a suggestion in place of the query; returns where the cursor goes.
    @discardableResult
    func apply(_ suggestion: Autocomplete.Suggestion, for query: Autocomplete.Query, in channel: Snowflake) -> Int {
        var draft = drafts[channel] ?? Draft()
        let insertion = suggestion.insertion
        let result = Autocomplete.insert(insertion.display, replacing: query.range, in: draft.text)
        let replacementCount = result.text.count - draft.text.count + query.range.count
        let tokens = Autocomplete.rebase(draft.tokens, replacing: query.range, replacementCount: replacementCount)
        draft.text = result.text
        draft.tokens = tokens
        if let wire = insertion.wire {
            let start = query.range.lowerBound
            draft.tokens.append(ComposerToken(display: insertion.display, wire: wire, range: start..<(start + insertion.display.count)))
        }
        drafts[channel] = draft
        if case .emoji(let emoji, _) = suggestion { settings.noteRecent(emoji) }
        return result.cursor
    }

    /// Asks Discord for members matching an @query (op 8), once per server
    /// and query, after typing pauses; the answer lands in the store.
    func searchMembers(_ query: String, guild: Snowflake) {
        memberSearch?.cancel()
        let key = "\(guild):\(query.lowercased())"
        guard !query.isEmpty, !memberQueries.contains(key), let gateway else { return }
        memberSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.memberQueries.insert(key)
            await gateway.requestMembers(guild: guild, query: query, limit: 10)
        }
    }

    func toggleReaction(_ emoji: Emoji, message: Snowflake, channel: Snowflake) {
        let mine = timeline(for: channel).messages.first { $0.id == message }?.reactions.first { $0.emoji.reactionKey == emoji.reactionKey }?.me ?? false
        react(emoji, add: !mine, message: message, channel: channel)
    }

    /// Shows the change at once and sends it (after any earlier write of the
    /// same reaction); a refused latest toggle puts the reaction back as
    /// Discord has it. Only a reaction that stuck joins Recently Used.
    func react(_ emoji: Emoji, add: Bool, message: Snowflake, channel: Snowflake) {
        guard let request = timeline(for: channel).sendReaction(emoji, on: message, add: add, api: api) else { return }
        Task {
            switch await request.value {
            case .applied:
                if add { settings.noteRecent(emoji) }
            case .failed:
                // The pill has already gone back; say why it moved.
                showError(add ? "Couldn't add reaction" : "Couldn't remove reaction")
            case .superseded:
                break
            }
        }
    }

    /// A failed action: a toast near the composer, an error haptic and a
    /// VoiceOver announcement.
    func showError(_ text: String) {
        let toast = Toast(text: text)
        withAnimation(.snappy(duration: 0.25)) { self.toast = toast }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        UIAccessibility.post(notification: .announcement, argument: text)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard let self, self.toast?.token == toast.token else { return }
            withAnimation(.snappy(duration: 0.25)) { self.toast = nil }
        }
    }

    func dismissToast() {
        withAnimation(.snappy(duration: 0.2)) { toast = nil }
    }

    // MARK: Background

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            store.refreshMuteExpirations()
            (gateway as? LiveGateway)?.nudge()
            notifications.flushPendingTap()
            reconcileKeepAlive()
        case .background:
            isActive = false
            store.visibleIsLive = false
            saveCache()
            reconcileKeepAlive()
        default:
            break
        }
    }

    func reconcileKeepAlive() {
        if phase == .signedIn, settings.keepAlive, !isMock, voice.call == nil {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
    }
}

/// Placeholder API before sign-in.
nonisolated struct OfflineAPI: DiscordAPI {
    private var error: Error { DiscordError.unauthorized }
    func messages(channel: Snowflake, before: Snowflake?, after: Snowflake?, around: Snowflake?, limit: Int) async throws -> [Message] { throw error }
    func pins(channel: Snowflake) async throws -> [Message] { throw error }
    func search(guild: Snowflake?, channel: Snowflake?, query: String, offset: Int) async throws -> SearchResult { throw error }
    func mentions(limit: Int, before: Snowflake?) async throws -> [Message] { throw error }
    func forumThreads(channel: Snowflake, offset: Int) async throws -> ThreadSearchResult { throw error }
    func archivedThreads(channel: Snowflake) async throws -> [Channel] { throw error }
    func publicArchivedThreads(channel: Snowflake, before: String?) async throws -> ArchivedThreadPage { throw error }
    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String) async throws -> Message { throw error }
    func edit(channel: Snowflake, message: Snowflake, content: String) async throws -> Message { throw error }
    func delete(channel: Snowflake, message: Snowflake) async throws { throw error }
    func ack(channel: Snowflake, message: Snowflake) async throws { throw error }
    func typing(channel: Snowflake) async throws { throw error }
    func react(channel: Snowflake, message: Snowflake, emoji: Emoji, add: Bool) async throws { throw error }
    func reactions(channel: Snowflake, message: Snowflake, emoji: Emoji, limit: Int) async throws -> [User] { throw error }
    func patchNotificationSettings(target: NotificationTarget, patch: NotificationPatch) async throws -> GuildSettingsUpdate { throw error }
    func relationship(user: Snowflake, action: RelationshipAction) async throws { throw error }
    func requestFriend(username: FriendUsername) async throws { throw error }
    func createDM(recipient: Snowflake) async throws -> Channel { throw error }
    func settingsProto() async throws -> String? { throw error }
}
