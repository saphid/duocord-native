import Foundation
import Observation
import os

/// How a timeline's message array changed, so the list can apply exactly
/// that change (and keep its scroll anchor) instead of reloading.
enum TimelineChange {
    case reset
    case prepended(Int)
    case appended(Int)
    case trimmedFront(Int)
    case trimmedBack(Int)
    case updated(Set<Snowflake>)
    case removed(Set<Snowflake>)
}

nonisolated enum SendState: Equatable, Hashable, Sendable {
    case sending
    /// Discord explicitly refused the final message POST.
    case failed(String)
    case notDispatched(String)
    case unknown(String)

    var recoveryTitle: String? {
        switch self {
        case .sending: nil
        case .failed, .notDispatched: "Retry Send"
        case .unknown: "Check Delivery"
        }
    }
}

/// One channel's loaded window of history plus pending sends.
@Observable
final class MessageTimeline {
    let channelID: Snowflake
    enum LoadState: Equatable { case idle, loading, failed(String) }

    private(set) var initialState: LoadState = .idle
    private(set) var loadingBefore = false
    private(set) var loadingAfter = false
    private(set) var hasMoreBefore = true
    private(set) var hasMoreAfter = false
    /// Newest-first IDs for which the window starts at the bottom of history.
    @ObservationIgnored private(set) var messages: [Message] = []
    @ObservationIgnored private(set) var sendStates: [String: SendState] = [:]
    @ObservationIgnored var onSendConfirmed: ((String, Message) -> Void)?
    @ObservationIgnored private var listeners: [UUID: (TimelineChange) -> Void] = [:]
    /// The newest message the list has shown; read state is acked up to it.
    @ObservationIgnored var lastAccess = Date.now
    /// The list's render cache (UI type, kept here so it outlives list views).
    @ObservationIgnored var renderCache: AnyObject?
    private(set) var revision = 0

    /// Keeps memory and layout work bounded in very long channels.
    static let windowLimit = 600
    static let pageSize = 50

    init(channelID: Snowflake) { self.channelID = channelID }

    var isAtLatest: Bool { !hasMoreAfter }

    /// Only current-session message text may shortcut an Inbox preview read.
    func cachedPreviewMessage(_ id: Snowflake) -> Message? {
        guard !isSeeded, !needsRefresh else { return nil }
        return messages.last { $0.id == id }
    }

    func observe(_ listener: @escaping (TimelineChange) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func stopObserving(_ id: UUID) { listeners[id] = nil }

    private func publish(_ change: TimelineChange) {
        revision &+= 1
        for listener in listeners.values { listener(change) }
    }

    func invalidatePrivacy() {
        renderCache = nil
        publish(.updated(Set(messages.map(\.id))))
    }

    func index(of id: Snowflake) -> Int? {
        // Confirmed history is sorted, but outgoing rows keep their own tail
        // regardless of ID. Search the bounded window in display order.
        messages.firstIndex { $0.id == id }
    }

    // MARK: Loading

    func loadLatest(api: DiscordAPI, store: DiscordStore) async {
        guard !Task.isCancelled else { return }
        // Even a cached latest intent supersedes paging from the old window.
        let wasLoading = initialState == .loading
        let generation = beginWindowIntent()
        if !wasLoading, hasLoadedLatest, !hasMoreAfter, !isSeeded, !needsRefresh {
            initialState = .idle
            return
        }
        activePageReads += 1
        let pinReadRevision = pinRevision
        defer { finishPageRead() }
        let wasSeeded = isSeeded
        if messages.isEmpty { initialState = .loading }
        do {
            let fetched = try await api.messages(channel: channelID, before: nil, after: nil, around: nil, limit: Self.pageSize)
            try Task.checkCancellation()
            guard generation == windowGeneration else { return }
            let page = acceptedPage(fetched, pinsSince: pinReadRevision)
            store.remember(messageAuthors: page)
            let fresh = page.sorted { $0.id < $1.id }
            initialState = .idle
            isSeeded = false
            needsRefresh = false
            // Merge, never replace: keep live messages that arrived during the
            // request, pending sends, and (when contiguous) older cached rows.
            let pending = messages.filter { isPending($0) }
            let confirmed = messages.filter { !isPending($0) }
            let freshIDs = Set(fresh.map(\.id))
            let newest = fresh.last?.id ?? 0
            let newer = confirmed.filter { $0.id > newest && !freshIDs.contains($0.id) }
            var older: [Message] = []
            if let first = fresh.first, (wasSeeded || hasLoadedLatest), confirmed.contains(where: { $0.id >= first.id }) || confirmed.isEmpty {
                older = confirmed.filter { $0.id < first.id }
            }
            let merged = older + fresh + newer
            let previous = Dictionary(confirmed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let edited = Set(fresh.filter { message in previous[message.id].map { $0 != message } ?? false }.map(\.id))
            let changedKnown = merged.count != messages.count - pending.count || zip(merged, confirmed).contains { $0.id != $1.id }
            messages = merged + pending
            hasMoreBefore = older.isEmpty ? fetched.count >= Self.pageSize : hasMoreBefore || fetched.count >= Self.pageSize
            hasMoreAfter = false
            hasLoadedLatest = true
            if changedKnown { publish(.reset) }
            // Messages edited while we were away re-render.
            if !edited.isEmpty || !changedKnown { publish(.updated(edited)) }
        } catch {
            guard generation == windowGeneration else { return }
            if Task.isCancelled || error is CancellationError { initialState = .idle }
            else if messages.isEmpty { initialState = .failed(error.localizedDescription) }
            else { initialState = .idle }
        }
    }

    @ObservationIgnored private var activePageReads = 0
    @ObservationIgnored private var readTombstones: Set<Snowflake> = []
    @ObservationIgnored private var pinRevision = 0
    /// Pin decisions made while history requests are in flight. Only reads
    /// started before a decision need it; the final read releases the entries.
    @ObservationIgnored private var pagePinOverrides: [Snowflake: (revision: Int, pinned: Bool)] = [:]

    private func notePinAuthority(_ id: Snowflake, pinned: Bool) {
        pinRevision &+= 1
        if activePageReads > 0 { pagePinOverrides[id] = (pinRevision, pinned) }
    }

    private func finishPageRead() {
        activePageReads -= 1
        if activePageReads == 0 {
            readTombstones.removeAll()
            pagePinOverrides.removeAll()
        }
    }

    private func visiblePage(_ page: [Message]) -> [Message] {
        page.filter { !readTombstones.contains($0.id) && pendingDeletes[$0.id] == nil }
    }

    /// Accept only a current response, then reconcile server-confirmed nonces.
    private func acceptedPage(_ fetched: [Message], pinsSince readRevision: Int) -> [Message] {
        var page = visiblePage(fetched)
        // A page read while your pin is in flight may predate it: keep your
        // intent showing, and roll back to what this read found if refused.
        for index in page.indices {
            let id = page[index].id
            if let decision = pagePinOverrides[id], decision.revision > readRevision {
                page[index].pinned = decision.pinned
            }
            guard let write = pendingPins[id] else { continue }
            if let gateway = write.gateway { page[index].pinned = gateway }
            else {
                pendingPins[id]?.server = page[index].pinned
                page[index].pinned = write.target
            }
        }
        for message in page {
            if let nonce = pendingNonce(matching: message) {
                sendStates[nonce] = nil
                onSendConfirmed?(nonce, message)
                let echoes = Set(messages.filter { $0.nonce == nonce }.map(\.id))
                messages.removeAll { $0.nonce == nonce }
                if !echoes.isEmpty { publish(.removed(echoes)) }
            }
        }
        return page
    }

    /// Local sends have their own lifetime; only confirmed history is bounded.
    private func trimHistory(fromFront: Bool) {
        let confirmed = messages.filter { !isPending($0) }
        let excess = confirmed.count - Self.windowLimit
        guard excess > 0 else { return }
        let removed = Set((fromFront ? Array(confirmed.prefix(excess)) : Array(confirmed.suffix(excess))).map(\.id))
        let hasPending = messages.contains { isPending($0) }
        messages.removeAll { removed.contains($0.id) }
        if fromFront { hasMoreBefore = true } else { hasMoreAfter = true }
        // Trimming behind a retained outgoing tail removes interior rows.
        if !fromFront && hasPending { publish(.reset) }
        else { publish(fromFront ? .trimmedFront(excess) : .trimmedBack(excess)) }
    }

    private func isPending(_ message: Message) -> Bool {
        message.nonce.map { sendStates[$0] != nil } ?? false
    }

    /// Set after a fresh gateway session: messages may have been missed.
    func markNeedsRefresh() { needsRefresh = true }
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var windowGeneration = 0

    @discardableResult
    private func beginWindowIntent() -> Int {
        windowGeneration &+= 1
        // Old paging requests still finish (and retain tombstones), but no
        // longer own flags or rows in the newly selected window.
        loadingBefore = false
        loadingAfter = false
        return windowGeneration
    }

    /// A reader chose a row already on screen, or the current latest window.
    /// Register synchronously before the controller scrolls or starts a task.
    func retainCurrentWindowForNavigation() {
        beginWindowIntent()
        initialState = .idle
    }
    @ObservationIgnored private(set) var hasLoadedLatest = false

    /// Opens the window around one message (search results, replies, pins).
    func load(around id: Snowflake, api: DiscordAPI, store: DiscordStore) async {
        guard !Task.isCancelled else { return }
        let generation = beginWindowIntent()
        if index(of: id) != nil { initialState = .idle; return }
        initialState = .loading
        activePageReads += 1
        let pinReadRevision = pinRevision
        defer { finishPageRead() }
        do {
            let fetched = try await api.messages(channel: channelID, before: nil, after: nil, around: id, limit: Self.pageSize)
            try Task.checkCancellation()
            guard generation == windowGeneration else { return }
            let page = acceptedPage(fetched, pinsSince: pinReadRevision)
            store.remember(messageAuthors: page)
            let pending = messages.filter { isPending($0) }
            messages = page.sorted { $0.id < $1.id } + pending
            hasLoadedLatest = false
            // A short side means that end of history is inside the page.
            let half = Self.pageSize / 2
            hasMoreBefore = fetched.filter { $0.id < id }.count >= half - 1
            hasMoreAfter = fetched.filter { $0.id > id }.count >= half - 1
            initialState = .idle
            publish(.reset)
        } catch {
            guard generation == windowGeneration else { return }
            initialState = Task.isCancelled || error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    func loadOlder(api: DiscordAPI, store: DiscordStore) async {
        guard hasMoreBefore, !loadingBefore, initialState == .idle,
              let oldest = messages.first(where: { !isPending($0) })?.id else { return }
        let generation = windowGeneration
        loadingBefore = true
        activePageReads += 1
        let pinReadRevision = pinRevision
        defer { finishPageRead() }
        let started = Date.now
        defer { Perf.shared.record("loadOlder", ["ms": Int(Date.now.timeIntervalSince(started) * 1000), "count": messages.count]) }
        defer { if generation == windowGeneration { loadingBefore = false } }
        do {
            let fetched = try await api.messages(channel: channelID, before: oldest, after: nil, around: nil, limit: Self.pageSize)
            try Task.checkCancellation()
            guard generation == windowGeneration,
                  messages.first(where: { !isPending($0) })?.id == oldest else { return }
            let page = acceptedPage(fetched, pinsSince: pinReadRevision)
            store.remember(messageAuthors: page)
            let older = page.filter { $0.id < oldest }.sorted { $0.id < $1.id }
            hasMoreBefore = fetched.count >= Self.pageSize
            guard !older.isEmpty else { return }
            messages.insert(contentsOf: older, at: 0)
            publish(.prepended(older.count))
            trimHistory(fromFront: false)
        } catch {
            Logger(subsystem: "com.saphid.duocord.native", category: "timeline").error("older history request failed")
        }
    }

    func loadNewer(api: DiscordAPI, store: DiscordStore) async {
        guard hasMoreAfter, !loadingAfter, initialState == .idle,
              let newest = messages.last(where: { !isPending($0) })?.id else { return }
        let generation = windowGeneration
        loadingAfter = true
        activePageReads += 1
        let pinReadRevision = pinRevision
        defer { finishPageRead() }
        defer { if generation == windowGeneration { loadingAfter = false } }
        do {
            let fetched = try await api.messages(channel: channelID, before: nil, after: newest, around: nil, limit: Self.pageSize)
            try Task.checkCancellation()
            guard generation == windowGeneration,
                  messages.last(where: { !isPending($0) })?.id == newest else { return }
            let page = acceptedPage(fetched, pinsSince: pinReadRevision)
            store.remember(messageAuthors: page)
            let newer = page.filter { $0.id > newest }.sorted { $0.id < $1.id }
            hasMoreAfter = fetched.count >= Self.pageSize
            guard !newer.isEmpty else { return }
            let position = messages.firstIndex(where: { isPending($0) }) ?? messages.count
            messages.insert(contentsOf: newer, at: position)
            publish(position == messages.count - newer.count ? .appended(newer.count) : .reset)
            trimHistory(fromFront: true)
        } catch {
            Logger(subsystem: "com.saphid.duocord.native", category: "timeline").error("newer history request failed")
        }
    }

    // MARK: Live updates

    func receive(_ message: Message) {
        guard !readTombstones.contains(message.id), pendingDeletes[message.id] == nil else { return }
        // A confirmed send replaces its local echo wherever the window is.
        if let nonce = pendingNonce(matching: message) {
            sendStates[nonce] = nil
            onSendConfirmed?(nonce, message)
            if let pending = messages.lastIndex(where: { $0.nonce == nonce }) {
                let echo = messages.remove(at: pending)
                publish(.removed([echo.id]))
            }
        }
        // Only extend the window when it reaches the newest history.
        guard !hasMoreAfter else { return }
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        let pending = messages.filter { isPending($0) }
        if !pending.isEmpty {
            // Keep local echoes last, after confirmed messages.
            messages.removeAll { isPending($0) }
            messages.append(message)
            messages.sort { $0.id < $1.id }
            messages.append(contentsOf: pending)
            publish(.reset)
        } else if let last = messages.last, last.id > message.id {
            messages.append(message)
            messages.sort { $0.id < $1.id }
            publish(.reset)
        } else {
            messages.append(message)
            publish(.appended(1))
        }
        trimHistory(fromFront: true)
    }

    func update(_ update: MessageUpdate) {
        var update = update
        if let pinned = update.pinned { notePinAuthority(update.id, pinned: pinned) }
        // Discord's word on the pin outranks your write in flight, either way.
        if let pinned = update.pinned, pendingPins[update.id] != nil {
            pendingPins[update.id]?.gateway = pinned
            pendingPins[update.id]?.server = pinned
        }
        if var edit = edits[update.id] {
            let stale = update.editedTimestamp.map { Self.isNewerEdit(edit.server.edited, than: $0) } ?? false
            if stale {
                update.content = nil
                update.editedTimestamp = nil
                update.embeds = nil
                update.messageSnapshots = nil
                update.components = nil
                update.poll = nil
                update.pollWasProvided = false
            } else {
                if let content = update.content {
                    edit.server = (content, update.editedTimestamp ?? edit.server.edited)
                    edit.serverFromGateway = true
                    if edit.sending?.content == content {
                        edit.sending?.echoed = true
                        if let generation = edit.sending?.generation,
                           edit.serverEmbeds?.pendingGeneration == generation,
                           let revision = update.editedTimestamp {
                            edit.serverEmbeds?.edited = revision
                            edit.serverEmbeds?.pendingGeneration = nil
                        }
                    }
                }
                if let embeds = update.embeds {
                    // Embed generation may precede the content echo, without a
                    // timestamp. Keep it tied to this request until its revision
                    // is known instead of labelling it as the pre-edit preview.
                    let revision = update.editedTimestamp
                    edit.serverEmbeds = (embeds, revision, true, revision == nil ? edit.sending?.generation : nil)
                }
            }
            edits[update.id] = edit
            // Keep a newer local save visible until its own response settles.
            if let index = index(of: update.id), let content = update.content, messages[index].content != content {
                update.content = nil
                update.editedTimestamp = nil
            }
        }
        guard let index = index(of: update.id) else { return }
        var message = messages[index]
        if let content = update.content { message.content = content }
        if let edited = update.editedTimestamp { message.editedTimestamp = edited }
        if let embeds = update.embeds { message.embeds = embeds }
        if let attachments = update.attachments { message.attachments = attachments }
        if let pinned = update.pinned { message.pinned = pinned }
        if let flags = update.flags { message.flags = flags }
        if let snapshots = update.messageSnapshots { message.messageSnapshots = snapshots }
        if let components = update.components { message.components = components }
        if update.pollWasProvided {
            if let poll = update.poll { message.poll = message.poll?.merging(poll) ?? poll }
            else { message.poll = nil }
        }
        guard message != messages[index] else { return }
        messages[index] = message
        publish(.updated([message.id]))
    }

    /// Keep known poll totals readable as live votes arrive. A delta cannot
    /// establish an unavailable baseline, and never grows the answer set.
    func pollVote(_ event: PollVoteEvent, add: Bool, me: Snowflake?) {
        guard let index = index(of: event.messageID), var poll = messages[index].poll,
              poll.results?.isFinalized != true,
              poll.answers?.contains(where: { $0.answerID == event.answerID }) == true,
              var counts = poll.results?.answerCounts else { return }
        if let answer = counts.firstIndex(where: { $0.id == event.answerID }) {
            if event.userID == me, counts[answer].meVoted == add { return }
            let old = max(0, counts[answer].count)
            counts[answer].count = add ? (old == Int.max ? old : old + 1) : max(0, old - 1)
            if event.userID == me { counts[answer].meVoted = add }
        } else if add, counts.count < 10 {
            counts.append(PollAnswerCount(id: event.answerID, count: 1, meVoted: event.userID == me))
        } else { return }
        poll.results?.answerCounts = counts
        guard messages[index].poll != poll else { return }
        messages[index].poll = poll
        publish(.updated([event.messageID]))
    }

    func remove(_ ids: Set<Snowflake>) {
        // Discord deleted it: a delete of yours still in flight is done,
        // whatever its response says (the row is usually gone already).
        for id in ids where pendingDeletes[id] != nil { pendingDeletes[id] = true }
        if activePageReads > 0 { readTombstones.formUnion(ids) }
        let before = messages.count
        for message in messages where ids.contains(message.id) {
            if let nonce = message.nonce { sendStates[nonce] = nil }
        }
        messages.removeAll { ids.contains($0.id) }
        if messages.count != before { publish(.removed(ids)) }
    }

    func react(_ event: ReactionEvent, add: Bool, me: Snowflake?) {
        guard let emoji = event.emoji else { return }
        let mine = event.userID == me
        let key = ReactionKey(message: event.messageID, emoji: emoji.reactionKey)
        // The late echo of a write Discord already applied (and the pill and
        // count already show): it belongs to that write, never a later one.
        if mine, consumeEcho(key, add: add) { return }
        if mine, var write = reactionWrites[key] {
            // Discord's word on your reaction while your writes are queued:
            // it confirms the request in flight (even if its HTTP response
            // later fails). The pill already shows your latest intent.
            write.confirmed = add
            if let sending = write.sending, sending.add == add, !sending.echoed {
                write.sending?.echoed = true
                noteReactionConfirmed(on: event.messageID)
            }
            reactionWrites[key] = write
            return
        }
        guard let index = index(of: event.messageID) else { return }
        var message = messages[index]
        let existing = message.reactions.firstIndex(where: { $0.emoji.reactionKey == emoji.reactionKey })
        // Your own change, already shown optimistically: the gateway only confirms it.
        if mine, (existing.map { message.reactions[$0].me } ?? false) == add { return }
        if let existing {
            message.reactions[existing].count += add ? 1 : -1
            if mine { message.reactions[existing].me = add }
            if message.reactions[existing].count <= 0 { message.reactions.remove(at: existing) }
        } else if add {
            message.reactions.append(Reaction(count: 1, me: mine, emoji: emoji))
        }
        messages[index] = message
        publish(.updated([message.id]))
    }

    /// Shows your reaction change at once, before Discord confirms it.
    /// Returns false when there was nothing to change (already in that state,
    /// or the message left the window). Rolling back is the opposite call.
    /// A new reaction goes at `position` when given (a rollback puts a
    /// removed pill back where it was), otherwise last.
    @discardableResult
    func setMyReaction(_ emoji: Emoji, on id: Snowflake, add: Bool, at position: Int? = nil) -> Bool {
        guard let index = index(of: id) else { return false }
        var message = messages[index]
        if let existing = message.reactions.firstIndex(where: { $0.emoji.reactionKey == emoji.reactionKey }) {
            guard message.reactions[existing].me != add else { return false }
            message.reactions[existing].me = add
            message.reactions[existing].count += add ? 1 : -1
            if message.reactions[existing].count <= 0 { message.reactions.remove(at: existing) }
        } else {
            guard add else { return false }
            let reaction = Reaction(count: 1, me: true, emoji: emoji)
            message.reactions.insert(reaction, at: min(position ?? message.reactions.count, message.reactions.count))
        }
        messages[index] = message
        publish(.updated([id]))
        return true
    }

    nonisolated enum ReactionOutcome: Equatable, Sendable {
        /// Discord has the reaction the way this toggle asked.
        case applied
        /// Refused, and this was your latest toggle: the pill went back.
        case failed
        /// A later toggle of the same reaction decides the outcome.
        case superseded
    }

    private struct ReactionKey: Hashable {
        let message: Snowflake
        let emoji: String
    }

    /// One message+emoji's reaction writes: your latest intent, what Discord
    /// is known to have, and the request in flight. Writes for a key go one
    /// at a time; toggles made meanwhile coalesce into `intent`.
    private struct ReactionWrite {
        var intent: Bool
        /// The newest toggle's operation id.
        var latest: Int
        var confirmed: Bool
        var preflight: @MainActor (Bool, Bool) -> Bool
        var failure: @MainActor (Error, Bool, Bool) async -> Void
        var sending: (op: Int, add: Bool, echoed: Bool)?
        /// Where the pill was before the first toggle (for a rollback).
        var position: Int?
        var worker: Task<(latest: Int, failed: Bool), Never>?
    }

    @ObservationIgnored private var reactionWrites: [ReactionKey: ReactionWrite] = [:]
    @ObservationIgnored private var lastReactionOp = 0
    /// Your writes Discord applied whose gateway echo hasn't arrived yet
    /// (true = add), oldest first. Kept after a key's writes finish, so a
    /// delayed echo is put down to the write that caused it.
    @ObservationIgnored private var unechoed: [ReactionKey: [Bool]] = [:]

    private func expectEcho(_ key: ReactionKey, add: Bool) {
        var pending = unechoed[key, default: []]
        pending.append(add)
        // An echo lost with a dropped connection can't be told apart from a
        // late one; a stale entry only ever costs a read after a lost response.
        unechoed[key] = Array(pending.suffix(8))
    }

    /// True when the echo matches an earlier applied write (echoes come in
    /// the order Discord applied them; any before it were lost).
    private func consumeEcho(_ key: ReactionKey, add: Bool) -> Bool {
        guard let pending = unechoed[key], let index = pending.firstIndex(of: add) else { return false }
        let rest = pending.dropFirst(index + 1)
        unechoed[key] = rest.isEmpty ? nil : Array(rest)
        return true
    }

    /// A new gateway session doesn't replay missed events: no echo is coming.
    func forgetPendingEchoes() { unechoed = [:] }
    /// Per message, bumped when Discord confirms one of your reaction
    /// writes: the reactors list refetches then and drops older results.
    private(set) var reactionConfirmations: [Snowflake: Int] = [:]

    private func noteReactionConfirmed(on id: Snowflake) {
        reactionConfirmations[id, default: 0] &+= 1
    }

    /// Excludes our optimistic contribution and restores our last confirmed
    /// contribution. A queued removal can turn an existing emoji into a new
    /// one, so this is checked again for each actual write.
    func hasConfirmedReaction(_ emoji: Emoji, on id: Snowflake) -> Bool {
        let key = ReactionKey(message: id, emoji: emoji.reactionKey)
        let shown = messages.first { $0.id == id }?.reactions.first { $0.emoji.reactionKey == emoji.reactionKey }
        let mine = reactionWrites[key]?.confirmed ?? (shown?.me ?? false)
        return (shown?.count ?? 0) - (shown?.me == true ? 1 : 0) + (mine ? 1 : 0) > 0
    }

    /// Your reaction: shown at once, then sent after any earlier write of
    /// the same reaction; put back as Discord has it if refused while still
    /// your latest toggle. Nil when there was nothing to change.
    @discardableResult
    func sendReaction(_ emoji: Emoji, on id: Snowflake, add: Bool, api: DiscordAPI,
                      start: @escaping @MainActor (Bool, Bool) -> Bool = { _, _ in true },
                      failure: @escaping @MainActor (Error, Bool, Bool) async -> Void = { _, _, _ in }) -> Task<ReactionOutcome, Never>? {
        let key = ReactionKey(message: id, emoji: emoji.reactionKey)
        let position = index(of: id).flatMap { messages[$0].reactions.firstIndex { $0.emoji.reactionKey == emoji.reactionKey } }
        guard setMyReaction(emoji, on: id, add: add) else { return nil }
        lastReactionOp &+= 1
        let op = lastReactionOp
        if var write = reactionWrites[key] {
            write.intent = add
            write.latest = op
            write.preflight = start
            write.failure = failure
            reactionWrites[key] = write
        } else {
            reactionWrites[key] = ReactionWrite(intent: add, latest: op, confirmed: !add, preflight: start, failure: failure, position: position)
            reactionWrites[key]?.worker = Task { await sendReactionWrites(key, emoji: emoji, api: api) }
        }
        guard let worker = reactionWrites[key]?.worker else { return nil }
        return Task {
            let result = await worker.value
            guard result.latest == op else { return .superseded }
            return result.failed ? .failed : .applied
        }
    }

    /// Sends one key's writes in turn until Discord has your latest intent.
    /// Only states you asked for are sent: a write already made moot by a
    /// later toggle is skipped, never undone with an extra request.
    private func sendReactionWrites(_ key: ReactionKey, emoji: Emoji, api: DiscordAPI) async -> (latest: Int, failed: Bool) {
        while var write = reactionWrites[key], write.intent != write.confirmed {
            let add = write.intent, op = write.latest
            write.sending = (op, add, false)
            reactionWrites[key] = write
            var accepted = true
            var learned: Bool?
            let existing = hasConfirmedReaction(emoji, on: key.message)
            do {
                // Remove the optimistic own contribution and put back the last
                // confirmed own state before deciding existing-vs-new emoji.
                guard !Task.isCancelled, write.preflight(add, existing) else {
                    throw CapabilityPreflightRefusal()
                }
                try await api.react(channel: channelID, message: key.message, emoji: emoji, add: add)
            } catch {
                Logger(subsystem: "com.saphid.duocord.native", category: "timeline")
                    .error("reaction request failed")
                // Its gateway event already arrived: Discord applied it.
                if reactionWrites[key]?.sending?.echoed != true, !(error is CapabilityPreflightRefusal) {
                    await write.failure(error, add, existing)
                }
                accepted = reactionWrites[key]?.sending?.echoed ?? false
                // A lost response may hide an applied write: ask Discord (a
                // read; nothing is sent) instead of guessing. An echo
                // arriving meanwhile still counts.
                if !accepted, !(error is CapabilityPreflightRefusal), DiscordError.mayHaveApplied(error) {
                    learned = await reactionOnServer(key, api: api)
                    accepted = (reactionWrites[key]?.sending?.echoed ?? false) || learned == add
                }
            }
            guard var write = reactionWrites[key] else { break }
            let echoed = write.sending?.echoed ?? false
            write.sending = nil
            if accepted {
                write.confirmed = add
                reactionWrites[key] = write
                if !echoed {
                    noteReactionConfirmed(on: key.message)
                    expectEcho(key, add: add)
                }
                continue
            }
            // What the read found beats what was last known.
            if let learned { write.confirmed = learned }
            if write.latest == op {
                // Still your latest wish: show what Discord has.
                reactionWrites[key] = nil
                setMyReaction(emoji, on: key.message, add: write.confirmed, at: write.position)
                return (op, true)
            } else {
                // A newer toggle decides what (if anything) to send next.
                reactionWrites[key] = write
            }
        }
        return (reactionWrites.removeValue(forKey: key)?.latest ?? 0, false)
    }

    /// Whether Discord has your reaction, read from the message itself
    /// (GET, never a write). Nil when the read fails.
    private func reactionOnServer(_ key: ReactionKey, api: DiscordAPI) async -> Bool? {
        do {
            let page = try await api.messages(channel: channelID, before: nil, after: nil, around: key.message, limit: 3)
            guard let message = page.first(where: { $0.id == key.message }) else { return nil }
            return message.reactions.first { $0.emoji.reactionKey == key.emoji }?.me ?? false
        } catch {
            Logger(subsystem: "com.saphid.duocord.native", category: "timeline")
                .error("reaction readback failed")
            return nil
        }
    }

    /// One message's edits: your newest save, the text Discord is known to
    /// have, and the request in flight. Saves go one at a time; one made moot
    /// by a newer save before it went out is never sent.
    private struct EditState {
        /// The newest save's generation.
        var latest: Int
        var server: (content: String, edited: String?)
        var serverFromGateway = false
        /// Embeds are a partial gateway field, with their own revision.
        var serverEmbeds: (value: [Embed], edited: String?, gateway: Bool, pendingGeneration: Int?)? = nil
        /// The request in flight, and whether Discord's MESSAGE_UPDATE for it arrived.
        var sending: (generation: Int, content: String, echoed: Bool)?
        /// The newest save's work; the next save waits for it.
        var tail: Task<Bool, Never>?
    }

    @ObservationIgnored private var edits: [Snowflake: EditState] = [:]
    @ObservationIgnored private var lastEditGeneration = 0
    /// Your deletes in flight: true once Discord's MESSAGE_DELETE arrived.
    @ObservationIgnored private var pendingDeletes: [Snowflake: Bool] = [:]

    /// Optimistically hidden rows still interrupt confirmed contiguity until
    /// their deletion is accepted. The current gateway event may confirm some.
    func hasUnresolvedDeletion(after lower: Snowflake, before upper: Snowflake, excluding confirmed: Set<Snowflake>) -> Bool {
        pendingDeletes.contains { id, echoed in
            !echoed && !confirmed.contains(id) && lower < id && id < upper
        }
    }

    /// Your edit: the new text shows at once, marked edited, then is sent
    /// after any earlier edit of the message; if Discord refuses your newest
    /// save, the text Discord has comes back (unless something else changed
    /// the message meanwhile). Nil when there is nothing to change. A save
    /// replaced by a newer one reports true; the newest decides.
    @discardableResult
    func sendEdit(_ id: Snowflake, content: String, api: DiscordAPI,
                  start: @escaping @MainActor () -> Bool = { true },
                  failure: @escaping @MainActor (Error) async -> Void = { _ in }) -> Task<Bool, Never>? {
        guard let index = index(of: id), messages[index].content != content else { return nil }
        let original = messages[index]
        var edited = original
        edited.content = content
        edited.editedTimestamp = ISO8601DateFormatter().string(from: .now)
        messages[index] = edited
        publish(.updated([id]))
        lastEditGeneration &+= 1
        let generation = lastEditGeneration
        var state = edits[id] ?? EditState(latest: generation, server: (original.content, original.editedTimestamp),
                                                      serverEmbeds: (original.embeds, original.editedTimestamp, false, nil))
        state.latest = generation
        let previous = state.tail
        let request = Task {
            _ = await previous?.value
            return await performEdit(id, content: content, generation: generation, api: api, start: start, failure: failure)
        }
        state.tail = request
        edits[id] = state
        return request
    }

    private func performEdit(_ id: Snowflake, content: String, generation: Int, api: DiscordAPI, start: @MainActor () -> Bool, failure: @MainActor (Error) async -> Void) async -> Bool {
        // A newer save replaced this text before it went out.
        guard var state = edits[id], state.latest == generation else { return true }
        state.sending = (generation, content, false)
        edits[id] = state
        var applied = true
        do {
            guard !Task.isCancelled, start() else { throw CapabilityPreflightRefusal() }
            let confirmed = try await api.edit(channel: channelID, message: id, content: content)
            guard var current = edits[id] else { return true }
            let useResponse = !Self.isNewerEdit(current.server.edited, than: confirmed.editedTimestamp)
                && (!current.serverFromGateway || Self.isNewerEdit(confirmed.editedTimestamp, than: current.server.edited))
            let sameRevision = current.server.content == confirmed.content
                && Self.sameEditRevision(current.server.edited, confirmed.editedTimestamp)
            if useResponse || sameRevision {
                if current.serverEmbeds?.pendingGeneration == generation {
                    current.serverEmbeds?.edited = confirmed.editedTimestamp
                    current.serverEmbeds?.pendingGeneration = nil
                }
                let gatewayHasField = current.serverEmbeds.map {
                    $0.gateway && (Self.sameEditRevision($0.edited, confirmed.editedTimestamp)
                                   || Self.isNewerEdit($0.edited, than: confirmed.editedTimestamp))
                } ?? false
                if !gatewayHasField { current.serverEmbeds = (confirmed.embeds, confirmed.editedTimestamp, false, nil) }
            }
            if useResponse {
                current.server = (confirmed.content, confirmed.editedTimestamp)
                current.serverFromGateway = false
            }
            edits[id] = current
            if current.latest == generation {
                edits[id] = nil
                update(MessageUpdate(id: id, channelID: channelID, content: current.server.content, editedTimestamp: current.server.edited,
                                     embeds: current.serverEmbeds?.value))
                return true
            }
        } catch {
            Logger(subsystem: "com.saphid.duocord.native", category: "timeline")
                .error("edit request failed")
            // Its gateway event already arrived: Discord saved it.
            if edits[id]?.sending?.echoed != true, !(error is CapabilityPreflightRefusal) { await failure(error) }
            applied = edits[id]?.sending?.echoed ?? false
        }
        guard var state = edits[id] else { return applied }
        state.sending = nil
        // A newer save is queued: it decides what the message says (and
        // whether there's an error to show).
        guard state.latest == generation else {
            edits[id] = state
            return true
        }
        edits[id] = nil
        if let index = index(of: id) {
            var restored = messages[index]
            restored.content = state.server.content
            restored.editedTimestamp = state.server.edited
            if let embeds = state.serverEmbeds { restored.embeds = embeds.value }
            if restored != messages[index] {
                messages[index] = restored
                publish(.updated([id]))
            }
        }
        return applied
    }

    private static func isNewerEdit(_ candidate: String?, than known: String?) -> Bool {
        guard let candidate else { return false }
        guard let known else { return true }
        return compareEditRevisions(candidate, known) == .orderedDescending
    }

    private static func sameEditRevision(_ a: String?, _ b: String?) -> Bool {
        if a == b { return true }
        guard let a, let b else { return false }
        return compareEditRevisions(a, b) == .orderedSame
    }

    /// Foundation truncates fractional seconds on some platforms. Parse only
    /// whole seconds as Date, then compare all fractional digits as decimals.
    private static func compareEditRevisions(_ a: String, _ b: String) -> ComparisonResult? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        func parts(_ value: String) -> (Date, String)? {
            var whole = value, fraction = ""
            if let dot = value.firstIndex(of: ".") {
                let tail = value[value.index(after: dot)...]
                fraction = String(tail.prefix { $0.isASCII && $0.isNumber })
                guard !fraction.isEmpty else { return nil }
                whole = String(value[..<dot]) + tail.dropFirst(fraction.count)
            }
            guard let date = formatter.date(from: whole) else { return nil }
            return (date, fraction)
        }
        guard let lhs = parts(a), let rhs = parts(b) else { return nil }
        if lhs.0 != rhs.0 { return lhs.0 < rhs.0 ? .orderedAscending : .orderedDescending }
        let width = max(lhs.1.count, rhs.1.count)
        let left = lhs.1 + String(repeating: "0", count: width - lhs.1.count)
        let right = rhs.1 + String(repeating: "0", count: width - rhs.1.count)
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    /// Your delete: the row goes at once, then the request is sent; the
    /// message comes back in place if Discord refuses it (unless Discord's
    /// MESSAGE_DELETE for it already arrived). Nil when the message isn't
    /// in the window.
    @discardableResult
    func sendDelete(_ id: Snowflake, api: DiscordAPI, start: @escaping @MainActor () -> Bool = { true },
                    failure: @escaping @MainActor (Error) async -> Void = { _ in }) -> Task<Bool, Never>? {
        guard let index = index(of: id), pendingDeletes[id] == nil else { return nil }
        let original = messages.remove(at: index)
        publish(.removed([id]))
        pendingDeletes[id] = false
        let channel = channelID
        return Task {
            defer { pendingDeletes[id] = nil; hiddenPinStates[id] = nil }
            do {
                guard !Task.isCancelled, start() else { throw CapabilityPreflightRefusal() }
                try await api.delete(channel: channel, message: id)
                if activePageReads > 0 { readTombstones.insert(id) }
                return true
            } catch {
                Logger(subsystem: "com.saphid.duocord.native", category: "timeline")
                    .error("delete request failed")
                // Its gateway event already arrived: Discord deleted it.
                if pendingDeletes[id] != true, !(error is CapabilityPreflightRefusal) { await failure(error) }
                if pendingDeletes[id] == true { return true }
                restore(original)
                return false
            }
        }
    }

    /// Your pin change in flight: what you asked for, what Discord last
    /// showed (a rollback goes back to it), and a gateway `pinned` value
    /// received meanwhile, which outranks the write.
    private struct PinWrite {
        var target: Bool
        var server: Bool
        var gateway: Bool?
    }

    @ObservationIgnored private var pendingPins: [Snowflake: PinWrite] = [:]
    /// Pins settled while your delete hid the row: a refused delete puts the row back with it.
    @ObservationIgnored private var hiddenPinStates: [Snowflake: Bool] = [:]

    func isChangingPin(_ id: Snowflake) -> Bool { pendingPins[id] != nil }

    /// Whether `message` may be pinned or unpinned here: a confirmed,
    /// non-system message you can see, in a channel where you may pin.
    func canChangePin(_ message: Message, store: DiscordStore) -> Bool {
        guard message.channelID == channelID, sendState(for: message) == nil, !message.isSystem,
              !store.hidesBlockedMessage(message), let channel = store.channel(channelID) else { return false }
        return store.canPin(in: channel)
    }

    /// Your pin or unpin: shown at once, then sent, unless `start` (checked
    /// just before the request) refuses. Refused by Discord, the row goes back
    /// to what Discord last showed, unless Discord's own update arrived
    /// meanwhile. `result` authorizes response publication and `completion`.
    /// Without it, a refused write may only remove its own optimistic value
    /// while `unwindUnsent` holds, without recording response authority or
    /// reaching `completion`. Nil when the message isn't in the window, already
    /// is that way, or a change of its pin is in flight. Yields whether Discord
    /// has the pin as asked.
    @discardableResult
    func sendPin(_ id: Snowflake, pinned: Bool, api: DiscordAPI, start: @escaping @MainActor () -> Bool = { true },
                 failure: @escaping @MainActor (Error) async -> Void = { _ in },
                 result: @escaping @MainActor () -> Bool = { true },
                 unwindUnsent: (@MainActor () -> Bool)? = nil,
                 completion: @escaping @MainActor (Bool) -> Void = { _ in }) -> Task<Bool, Never>? {
        guard pendingPins[id] == nil, let position = index(of: id), messages[position].pinned != pinned else { return nil }
        pendingPins[id] = PinWrite(target: pinned, server: messages[position].pinned)
        messages[position].pinned = pinned
        publish(.updated([id]))
        let channel = channelID
        return Task {
            defer { pendingPins[id] = nil }
            let applied: Bool
            var requested = false
            if Task.isCancelled || !start() || pendingPins[id]?.gateway != nil || index(of: id) == nil {
                // Never sent: Discord already decided, or this is no longer yours to send.
                applied = pendingPins[id]?.gateway == pinned
            } else {
                requested = true
                do {
                    try await api.setPinned(channel: channel, message: id, pinned: pinned)
                    applied = true
                } catch {
                    Logger(subsystem: "com.saphid.duocord.native", category: "timeline")
                        .error("pin request failed")
                    // Its gateway event already arrived: Discord applied it.
                    if pendingPins[id]?.gateway != pinned { await failure(error) }
                    applied = pendingPins[id]?.gateway == pinned
                }
            }
            guard let write = pendingPins[id] else { return applied }
            // An obsolete refusal can remove this write's own optimism using
            // the current server value, but cannot publish its response or toast.
            if requested && !result() {
                if !applied && (unwindUnsent?() ?? false) {
                    settlePin(id, pinned: write.gateway ?? write.server, replacing: write.target)
                }
                return applied
            }
            // A never-sent intent can undo its own optimistic value under the
            // caller's narrower unwind policy. A response needs full authority.
            guard requested || (unwindUnsent?() ?? result()) else { return applied }
            if requested { notePinAuthority(id, pinned: write.gateway ?? (applied ? write.target : write.server)) }
            // A sent write's gateway value is authoritative. An unsent intent
            // may only unwind the optimistic value it put on the row.
            settlePin(id, pinned: write.gateway ?? (applied ? write.target : write.server),
                      replacing: requested && write.gateway != nil ? nil : write.target)
            completion(applied)
            return applied
        }
    }

    /// Shows the settled pin, only over the value this write put there.
    private func settlePin(_ id: Snowflake, pinned: Bool, replacing optimistic: Bool?) {
        guard let position = index(of: id) else {
            if pendingDeletes[id] != nil { hiddenPinStates[id] = pinned }
            return
        }
        if let optimistic, messages[position].pinned != optimistic { return }
        guard messages[position].pinned != pinned else { return }
        messages[position].pinned = pinned
        publish(.updated([id]))
    }

    /// Puts a message back in ID order (before pending sends), if the
    /// window still covers where it was.
    private func restore(_ message: Message) {
        guard index(of: message.id) == nil else { return }
        var message = message
        let settled = hiddenPinStates.removeValue(forKey: message.id)
        if let pinned = pendingPins[message.id]?.gateway ?? settled { message.pinned = pinned }
        let confirmed = messages.filter { !isPending($0) }
        if let first = confirmed.first, message.id < first.id, hasMoreBefore { return }
        if let last = confirmed.last, message.id > last.id, hasMoreAfter { return }
        let position = messages.firstIndex { isPending($0) || $0.id > message.id } ?? messages.count
        messages.insert(message, at: position)
        publish(.reset)
    }

    func clearReactions(message id: Snowflake, emoji: Emoji?) {
        // Discord no longer has your reaction either.
        for key in reactionWrites.keys where key.message == id && (emoji == nil || key.emoji == emoji?.reactionKey) {
            reactionWrites[key]?.confirmed = false
        }
        // Echoes come in order: any still awaited from before this were lost.
        for key in unechoed.keys where key.message == id && (emoji == nil || key.emoji == emoji?.reactionKey) {
            unechoed[key] = nil
        }
        guard let index = index(of: id) else { return }
        if let emoji { messages[index].reactions.removeAll { $0.emoji.reactionKey == emoji.reactionKey } }
        else { messages[index].reactions = [] }
        publish(.updated([id]))
    }

    // MARK: Sending

    /// Appends a local echo shown as "sending" until the gateway confirms it.
    func addPending(_ message: Message) {
        guard let nonce = message.nonce else { return }
        sendStates[nonce] = .sending
        messages.append(message)
        publish(.appended(1))
    }

    private func pendingNonce(matching message: Message) -> String? {
        guard message.channelID == channelID, let nonce = message.nonce, sendStates[nonce] != nil,
              messages.contains(where: { $0.nonce == nonce && $0.author.id == message.author.id }) else { return nil }
        return nonce
    }

    func markFailed(nonce: String, error: String) {
        setSendState(nonce: nonce, state: .failed(error))
    }

    func setSendState(nonce: String, state: SendState) {
        guard sendStates[nonce] != nil, let index = messages.lastIndex(where: { $0.nonce == nonce }) else { return }
        sendStates[nonce] = state
        publish(.updated([messages[index].id]))
    }

    func confirm(nonce: String, with message: Message) {
        guard sendStates[nonce] != nil else { return }
        // HTTP can omit nonce. The caller already correlated this response to
        // the attempt; receive still validates channel and pending author.
        var message = message
        guard message.nonce == nil || message.nonce == nonce else { return }
        message.nonce = nonce
        receive(message)
    }

    func discardPending(nonce: String) {
        guard sendStates[nonce] != nil else { return }
        sendStates[nonce] = nil
        guard let index = messages.lastIndex(where: { $0.nonce == nonce }) else { return }
        let id = messages[index].id
        messages.remove(at: index)
        publish(.removed([id]))
    }

    func sendState(for message: Message) -> SendState? {
        message.nonce.flatMap { sendStates[$0] }
    }

    func resetWindow() {
        beginWindowIntent()
        messages = messages.filter { isPending($0) }
        hasLoadedLatest = false
        hasMoreBefore = true
        hasMoreAfter = false
        initialState = .idle
    }

    /// Restores a cached page for an instant first frame on cold start.
    func seed(_ cached: [Message]) {
        guard messages.isEmpty, !cached.isEmpty else { return }
        messages = cached.sorted { $0.id < $1.id }
        hasMoreBefore = true
        isSeeded = true
        publish(.reset)
    }

    /// The window came from the disk cache and still needs a network refresh.
    @ObservationIgnored private(set) var isSeeded = false
}

/// Owns every channel's timeline and routes gateway message events to them.
@Observable
final class MessageCenter {
    @ObservationIgnored private var timelines: [Snowflake: MessageTimeline] = [:]
    @ObservationIgnored private let cacheLimit = 24

    func timeline(for channel: Snowflake) -> MessageTimeline {
        if let existing = timelines[channel] {
            existing.lastAccess = .now
            return existing
        }
        let timeline = MessageTimeline(channelID: channel)
        timelines[channel] = timeline
        evictIfNeeded(keeping: channel)
        return timeline
    }

    func existingTimeline(for channel: Snowflake) -> MessageTimeline? { timelines[channel] }

    private func evictIfNeeded(keeping channel: Snowflake) {
        guard timelines.count > cacheLimit else { return }
        let victims = timelines.values.filter { $0.channelID != channel && $0.sendStates.isEmpty }
            .sorted { $0.lastAccess < $1.lastAccess }
            .prefix(timelines.count - cacheLimit)
        for victim in victims { timelines[victim.channelID] = nil }
    }

    func handle(_ dispatch: GatewayDispatch, me: Snowflake?) {
        switch dispatch.name {
        case "MESSAGE_UPDATE":
            if let update = try? dispatch.decode(MessageUpdate.self) { timelines[update.channelID]?.update(update) }
        case "MESSAGE_POLL_VOTE_ADD", "MESSAGE_POLL_VOTE_REMOVE":
            if let event = try? dispatch.decode(PollVoteEvent.self) {
                timelines[event.channelID]?.pollVote(event, add: dispatch.name == "MESSAGE_POLL_VOTE_ADD", me: me)
            }
        case "MESSAGE_DELETE":
            if let deleted = try? dispatch.decode(MessageDelete.self) { timelines[deleted.channelID]?.remove([deleted.id]) }
        case "MESSAGE_DELETE_BULK":
            if let deleted = try? dispatch.decode(MessageDeleteBulk.self) { timelines[deleted.channelID]?.remove(Set(deleted.ids)) }
        case "MESSAGE_REACTION_ADD", "MESSAGE_REACTION_REMOVE":
            if let event = try? dispatch.decode(ReactionEvent.self) {
                timelines[event.channelID]?.react(event, add: dispatch.name == "MESSAGE_REACTION_ADD", me: me)
            }
        case "MESSAGE_REACTION_REMOVE_ALL", "MESSAGE_REACTION_REMOVE_EMOJI":
            if let event = try? dispatch.decode(ReactionEvent.self) {
                timelines[event.channelID]?.clearReactions(message: event.messageID, emoji: event.emoji)
            }
        default:
            break
        }
    }

    func received(_ message: Message) {
        timelines[message.channelID]?.receive(message)
    }

    func invalidatePrivacy() { timelines.values.forEach { $0.invalidatePrivacy() } }

    func reset() { timelines = [:] }

    /// A new gateway session (not a resume): any timeline may have gaps.
    func markAllNeedRefresh() {
        timelines.values.forEach {
            $0.markNeedsRefresh()
            $0.forgetPendingEchoes()
        }
    }
}
