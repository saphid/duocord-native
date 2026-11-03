import SwiftUI
import Observation

/// The latest unread message under an Inbox unread row. A preview loads only
/// while its row is on screen, a few at a time, and loading never acknowledges.
@MainActor @Observable
final class InboxPreviews {
    /// Fences a preview to the session, account, transport, newest message
    /// and read boundary it was requested for. Any change makes a new key.
    struct Key: Hashable {
        let channel: Snowflake
        let latest: Snowflake
        let boundary: Snowflake
        let session: UUID
        let account: Snowflake?
        let api: ObjectIdentifier
        var contentRevision: UInt64 = 0

        /// Nil when the channel has nothing unread to preview (mentions only).
        static func current(_ channel: Snowflake, store: DiscordStore, api: ObjectIdentifier) -> Key? {
            guard let info = store.channel(channel), !store.isUnresolvedThread(info), store.canView(info),
                  store.permissions(in: info) & Permission.readHistory != 0,
                  store.isUnread(info), let latest = info.lastMessageID, let boundary = store.readBoundary(info) else { return nil }
            return Key(channel: channel, latest: latest, boundary: boundary,
                       session: store.readEpoch, account: store.me?.id, api: api,
                       contentRevision: store.messageContentRevisions[channel, default: 0])
        }
    }

    enum Entry: Equatable {
        case loading
        case loaded(Message)
        case empty
        case failed(String)

        var message: Message? {
            if case .loaded(let message) = self { return message }
            return nil
        }
    }

    typealias Load = @MainActor () async throws -> [Message]

    private(set) var entries: [Key: Entry] = [:]
    @ObservationIgnored private var requests: [Key: (load: Load, isCurrent: @MainActor () -> Bool)] = [:]
    @ObservationIgnored private var pending: [Key] = []
    @ObservationIgnored private var running: [Key: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var generation = UUID()
    let concurrency: Int

    init(concurrency: Int = 2) { self.concurrency = max(1, concurrency) }

    var inFlight: Int { running.count }

    func entry(for key: Key?) -> Entry? { key.flatMap { entries[$0] } }

    /// The production request: one newest message, read without acknowledging.
    nonisolated static func latestMessage(api: DiscordAPI, channel: Snowflake) async throws -> [Message] {
        try await api.messages(channel: channel, before: nil, after: nil, around: nil, limit: 1)
    }

    /// A row came on screen. An already loaded newest message needs no request.
    func appear(_ key: Key, cached: Message?, load: @escaping Load, isCurrent: @escaping @MainActor () -> Bool) {
        for old in Array(entries.keys) where old.channel == key.channel && old != key { drop(old) }
        if entries[key] != nil { return }
        if let cached, cached.id == key.latest, Self.accepts(cached, for: key) {
            entries[key] = .loaded(cached)
            return
        }
        entries[key] = .loading
        requests[key] = (load, isCurrent)
        pending.append(key)
        pump()
    }

    /// A row left the screen: a queued or in-flight load stops; a finished
    /// preview stays for scrolling back.
    func disappear(_ key: Key) {
        guard entries[key] == .loading else { return }
        drop(key)
        pump()
    }

    func retry(_ key: Key, load: @escaping Load, isCurrent: @escaping @MainActor () -> Bool) {
        drop(key)
        appear(key, cached: nil, load: load, isCurrent: isCurrent)
    }

    func invalidate() {
        generation = UUID()
        for request in running.values { request.task.cancel() }
        running = [:]; pending = []; requests = [:]; entries = [:]
    }

    /// Only this channel's newest unread message can stand for the row.
    static func accepts(_ message: Message, for key: Key) -> Bool {
        message.channelID == key.channel && message.id > key.boundary && message.id <= key.latest
    }

    private func drop(_ key: Key) {
        running[key]?.task.cancel(); running[key] = nil
        pending.removeAll { $0 == key }
        requests[key] = nil; entries[key] = nil
    }

    private func pump() {
        while running.count < concurrency, !pending.isEmpty {
            let key = pending.removeFirst()
            guard let request = requests[key] else { continue }
            let token = UUID(), accepted = generation
            let task = Task { @MainActor [weak self] in
                let result: Result<[Message], Error>
                do { result = .success(try await request.load()) } catch { result = .failure(error) }
                self?.finish(key, token: token, generation: accepted, result: result)
            }
            running[key] = (token, task)
        }
    }

    private func finish(_ key: Key, token: UUID, generation accepted: UUID, result: Result<[Message], Error>) {
        guard generation == accepted, running[key]?.token == token else { return }
        running[key] = nil
        let isCurrent = requests[key]?.isCurrent
        requests[key] = nil
        defer { pump() }
        guard !Task.isCancelled, isCurrent?() == true else { entries[key] = nil; return }
        switch result {
        case .success(let rows):
            let newest = rows.filter { Self.accepts($0, for: key) }.max { $0.id < $1.id }
            entries[key] = newest.map(Entry.loaded) ?? .empty
        case .failure(let error as DiscordError):
            if case .http(let code, _) = error, code == 403 || code == 404 {
                entries[key] = .failed("You can't read this conversation's history.")
            } else {
                entries[key] = .failed(error.localizedDescription)
            }
        case .failure(is CancellationError):
            entries[key] = nil
        case .failure(let error):
            entries[key] = .failed(error.localizedDescription)
        }
    }
}

/// Where an unread row lives: a thread names its parent channel and server.
enum InboxRowLocation {
    static func describe(_ channel: Channel, store: DiscordStore) -> (title: String, detail: String?) {
        if channel.type.isPrivate { return (store.dmName(channel), nil) }
        let guild = channel.guildID.flatMap { store.guilds[$0]?.name }
        guard channel.type.isThread else { return (store.channelName(channel), guild) }
        let parent = channel.parentID.flatMap { store.channel($0) }.map { "#\(store.channelName($0))" }
        return (store.channelName(channel), [parent.map { "Thread in \($0)" } ?? "Parent channel unavailable", guild].compactMap { $0 }.joined(separator: " · "))
    }
}

/// An Inbox unread row: location, mentions and the latest unread message.
/// Opening it selects the conversation; the reader then lands at its unread
/// boundary. Loading the preview never marks anything read.
struct InboxUnreadRow: View {
    @Environment(AppModel.self) private var model
    @Environment(DiscordStore.self) private var store
    let channel: Channel
    let previews: InboxPreviews
    @State private var reveal: ExcerptRevealScope?

    private var key: InboxPreviews.Key? {
        InboxPreviews.Key.current(channel.id, store: store, api: ObjectIdentifier(model.api as AnyObject))
    }

    var body: some View {
        let key = key
        let location = InboxRowLocation.describe(channel, store: store)
        let mentions = store.mentionCount(channel.id)
        let entry = previews.entry(for: key)
        let message = entry?.message
        let content = message.map { MessageExcerptPresentation(message: $0, store: store, reveal: reveal) }
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.open(channel: channel.id, message: nil)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ChannelRow.symbol(for: channel)).foregroundStyle(Color.textMuted).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(location.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let detail = location.detail {
                            Text(detail).font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                        }
                        preview(key: key, entry: entry, message: message, content: content)
                    }
                    Spacer(minLength: 0)
                    if mentions > 0 { MentionBadge(count: mentions) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(mentions > 0 ? "\(mentions) mention\(mentions == 1 ? "" : "s")" : "")
            .accessibilityHint("Opens the conversation at its unread messages")
            if let content, content.concealed {
                Button("Reveal message") { reveal = content.scope }
                    .font(.subheadline).buttonStyle(.borderless)
                    .accessibilityHint("Reveals this excerpt only")
            }
            if case .failed? = entry, let key {
                Button("Retry Preview") { previews.retry(key, load: load(key), isCurrent: isCurrent(key)) }
                    .font(.subheadline).buttonStyle(.borderless)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .onAppear { start(key) }
        .onDisappear { if let key { previews.disappear(key) } }
        .onChange(of: key) { old, new in
            if let old { previews.disappear(old) }
            start(new)
        }
    }

    @ViewBuilder
    private func preview(key: InboxPreviews.Key?, entry: InboxPreviews.Entry?, message: Message?,
                         content: MessageExcerptPresentation?) -> some View {
        if key == nil {
            if store.isUnresolvedThread(channel) {
                Text("Open to load the parent channel").font(.caption).foregroundStyle(Color.textMuted)
            }
        } else if let message, let content {
            if content.concealed {
                Text("Blocked user").font(.caption.weight(.semibold)).foregroundStyle(Color.textMuted)
            } else {
                HStack(spacing: 6) {
                    Text(store.displayName(for: message.author, in: channel.guildID))
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary).lineLimit(1)
                    Text(MessageBuilder.stamp(message.date)).font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                }
            }
            SnippetView(message: message, reveal: reveal).multilineTextAlignment(.leading)
        } else {
            switch entry {
            case .empty?:
                Text("No unread message preview").font(.caption).foregroundStyle(Color.textMuted)
            case .failed(let reason)?:
                Text("Preview unavailable. \(reason)").font(.caption).foregroundStyle(Color.textMuted).lineLimit(2)
            default:
                Label("Loading latest message", systemImage: "ellipsis")
                    .font(.caption).foregroundStyle(Color.textMuted)
            }
        }
    }

    private func start(_ key: InboxPreviews.Key?) {
        guard let key else { return }
        let cached = model.messages.existingTimeline(for: key.channel)?.cachedPreviewMessage(key.latest)
        previews.appear(key, cached: cached, load: load(key), isCurrent: isCurrent(key))
    }

    private func load(_ key: InboxPreviews.Key) -> InboxPreviews.Load {
        let api = model.api
        return { try await InboxPreviews.latestMessage(api: api, channel: key.channel) }
    }

    private func isCurrent(_ key: InboxPreviews.Key) -> @MainActor () -> Bool {
        let model = model, store = store
        return { model.phase == .signedIn && InboxPreviews.Key.current(key.channel, store: store, api: ObjectIdentifier(model.api as AnyObject)) == key }
    }
}
