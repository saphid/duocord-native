import Foundation
import Observation

struct LookupPage<Row> {
    var rows: [Row]
    var consumed: Int
    var total: Int? = nil
    var hasMore: Bool
    var firstMessages: [Snowflake: Message] = [:]
    var reconcile: (@MainActor ([Row]) -> [Row])? = nil
}

struct SearchPageIdentity: Equatable {
    let submission: SearchSubmission
    let presentation: UUID
    let sidebar: Bool
    let navigation: UUID

    /// Opening a result (or any other navigation) is a new identity, which
    /// hides the results it fenced. With the same query, scope, account and
    /// panel, it is the same request the person already made: run it again
    /// rather than leave the open panel blank.
    func repeatsRequest(of previous: SearchPageIdentity?) -> Bool {
        guard let previous, self != previous else { return false }
        guard presentation == previous.presentation, sidebar == previous.sidebar else { return false }
        let now = submission, then = previous.submission
        let sameAccount = now.context.session == then.context.session && now.context.account == then.context.account
        let sameScope = now.guild == then.guild && now.channel == then.channel && now.scopeName == then.scopeName
        return sameAccount && sameScope && now.query == then.query
    }
}

struct ForumSubmission: Equatable {
    let context: LookupContext
    let forum: Snowflake
    let presentation: UUID
    let navigation: UUID
}

/// Finite, explicitly requested pages. A generation and a page token fence
/// cancellation-ignoring transports; validation and publication never suspend.
@MainActor @Observable
final class LookupPagingState<Input: Equatable, Row: Identifiable> where Row.ID == Snowflake {
    enum Status: Equatable { case idle, loading, done, failed(String) }
    typealias More = LookupPageProgress
    struct Snapshot {
        var input: Input?
        var rows: [Row] = []
        var firstMessages: [Snowflake: Message] = [:]
        var consumed = 0
        var total: Int? = nil
        var status: Status = .idle
        var more: More = .finished("")
    }
    private var current = Snapshot()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pageID: UUID?
    @ObservationIgnored private var load: (@MainActor (Int) async throws -> LookupPage<Row>)?
    @ObservationIgnored private var isCurrent: (@MainActor () -> Bool)?
    @ObservationIgnored private var publish: (@MainActor (LookupPage<Row>) -> Void)?
    // Application policy, not a claimed Discord service limit.
    let positionLimit: Int

    init(positionLimit: Int = 1_000) { self.positionLimit = max(1, positionLimit) }

    func snapshot(for input: Input?) -> Snapshot {
        guard let input, input == current.input else { return Snapshot() }
        return current
    }

    func invalidate(unless input: Input? = nil) {
        if let input, current.input == input { return }
        generation = UUID(); pageID = nil
        task?.cancel(); task = nil
        load = nil; isCurrent = nil; publish = nil
        current = Snapshot()
    }

    @discardableResult
    func start(_ input: Input, load: @escaping @MainActor (Int) async throws -> LookupPage<Row>,
               isCurrent: @escaping @MainActor () -> Bool,
               publish: @escaping @MainActor (LookupPage<Row>) -> Void = { _ in }) -> Task<Void, Never> {
        invalidate()
        self.load = load; self.isCurrent = isCurrent; self.publish = publish
        current = Snapshot(input: input, status: .loading)
        return request(input, initial: true)
    }

    @discardableResult
    func loadMore(_ input: Input) -> Task<Void, Never>? {
        guard current.input == input, current.status == .done, pageID == nil else { return nil }
        switch current.more {
        case .ready, .failed: return request(input, initial: false)
        case .loading, .finished: return nil
        }
    }

    private func request(_ input: Input, initial: Bool) -> Task<Void, Never> {
        let accepted = generation, token = UUID(), offset = current.consumed
        // Capture all request authority before suspension, including append API.
        let load = self.load!, isCurrent = self.isCurrent!, publish = self.publish!
        pageID = token
        if !initial { current.more = .loading }
        let request = Task { @MainActor in
            guard accepts(accepted, token, isCurrent: isCurrent) else { return }
            do {
                let page = try await load(offset)
                guard accepts(accepted, token, isCurrent: isCurrent) else { return }
                let count = max(0, page.consumed)
                let (next, overflow) = offset.addingReportingOverflow(count)
                // Reject a straddling page in full before any row, association
                // or cache publication. Raw positions cannot be safely trimmed
                // from already filtered and deduplicated response rows.
                guard !overflow, next <= positionLimit else {
                    current.status = .done
                    current.more = .finished("The next page exceeds the \(positionLimit.formatted()) server position browsing limit. Reload or refine your search.")
                    pageID = nil; self.task = nil
                    return
                }
                var seen = Set(current.rows.map(\.id))
                let unique = page.rows.filter { seen.insert($0.id).inserted }
                let added = page.reconcile?(unique) ?? unique
                var firsts: [Snowflake: Message] = [:]
                // Revalidate against the retained row, not a duplicate page's
                // potentially different owner/guild. Missing-message fallback
                // concealment must not be replaced by an unrelated author.
                let posts = (current.rows + added).compactMap { $0 as? Channel }
                let acceptedPosts = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
                for (id, message) in page.firstMessages where current.firstMessages[id] == nil {
                    guard let post = acceptedPosts[id], ForumFirstMessage.accepts(message, post: post) else { continue }
                    firsts[id] = message
                }
                // Only accepted, unique rows reach caches; duplicate thread
                // records cannot overwrite a known first-message association.
                var publication = page
                publication.rows = added; publication.firstMessages = firsts
                publish(publication)
                current.rows.append(contentsOf: added)
                current.firstMessages.merge(firsts, uniquingKeysWith: { known, _ in known })
                current.consumed = next
                let changedTotal = !initial && current.total != page.total
                current.total = page.total
                current.status = .done
                if current.consumed >= positionLimit {
                    current.more = .finished("Browsing is limited to \(positionLimit.formatted()) server positions. Reload or refine your search.")
                } else if count == 0 || added.isEmpty && page.hasMore {
                    current.more = .finished("No new rows were returned. Reload or refine your search to try again.")
                } else if changedTotal || page.total.map({ $0 < current.consumed }) == true {
                    current.more = .finished("The reported result total changed or was inconsistent. Reload or refine your search.")
                } else if !page.hasMore || page.total.map({ current.consumed >= $0 }) == true {
                    current.more = .finished("All returned results loaded.")
                } else {
                    current.more = .ready
                }
                pageID = nil; self.task = nil
            } catch {
                guard accepts(accepted, token, isCurrent: isCurrent) else { return }
                if initial { current.status = .failed(error.localizedDescription) }
                else { current.more = .failed(error.localizedDescription) }
                pageID = nil; self.task = nil
            }
        }
        task = request
        return request
    }

    private func accepts(_ accepted: UUID, _ token: UUID, isCurrent: () -> Bool) -> Bool {
        guard generation == accepted, pageID == token else { return false }
        guard !Task.isCancelled, isCurrent() else { invalidate(); return false }
        return true
    }
}

extension LookupPage where Row == Message {
    static func search(_ result: SearchResult) -> Self {
        Self(rows: result.messages, consumed: result.consumedCount, total: result.totalResults,
             hasMore: result.consumedCount < result.totalResults)
    }
}

extension LookupPage where Row == Channel {
    static func forum(_ result: ThreadSearchResult, forum: Channel,
                      store: DiscordStore? = nil, since revision: Int? = nil) -> Self {
        let rows = result.threads.filter {
            $0.type.isThread && $0.parentID == forum.id &&
            ($0.guildID == nil || forum.guildID == nil || $0.guildID == forum.guildID)
        }
        var posts: [Snowflake: Channel] = [:]
        for post in rows where posts[post.id] == nil { posts[post.id] = post }
        var firsts: [Snowflake: Message] = [:]
        for message in result.firstMessages {
            guard let post = posts[message.channelID], ForumFirstMessage.accepts(message, post: post),
                  firsts[post.id] == nil else { continue }
            firsts[post.id] = message
        }
        var page = Self(rows: rows, consumed: result.threads.count, hasMore: result.hasMore, firstMessages: firsts)
        if let store, let revision {
            page.reconcile = { rows in
                rows.compactMap { row in
                    guard store.channelChanged(row.id, since: revision) else { return row }
                    guard let current = store.channel(row.id), current.type.isThread,
                          current.parentID == forum.id,
                          current.guildID == nil || forum.guildID == nil || current.guildID == forum.guildID else { return nil }
                    return current
                }
            }
        }
        return page
    }
}

/// A thread's opening message shares its thread/channel identity. Incomplete
/// or inconsistent metadata keeps the existing owner-only concealment fallback.
enum ForumFirstMessage {
    static func accepts(_ message: Message, post: Channel) -> Bool {
        message.channelID == post.id && message.id == post.id &&
        (message.guildID == nil || post.guildID == nil || message.guildID == post.guildID) &&
        (post.ownerID == nil || post.ownerID == message.author.id)
    }
}
