import Foundation
import Observation

/// Identity is shared by sheet and sidebar consumers. Current signed-in
/// transports (DiscordREST and MockDiscord) have stable reference identities.
struct OtherListIdentity: Equatable {
    let context: LookupContext
    let route: AppSheet
    let parent: Channel?
    let api: ObjectIdentifier
    let presentation: UUID
    let sidebar: Bool
    let navigation: UUID

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.context == rhs.context && lhs.route == rhs.route &&
        lhs.parent?.id == rhs.parent?.id && lhs.parent?.guildID == rhs.parent?.guildID &&
        lhs.parent?.type == rhs.parent?.type && lhs.api == rhs.api &&
        lhs.presentation == rhs.presentation && lhs.sidebar == rhs.sidebar && lhs.navigation == rhs.navigation
    }

    static func current(model: AppModel, store: DiscordStore, route: AppSheet,
                        parent: Channel? = nil, presentation: UUID, sidebar: Bool) -> Self? {
        guard model.phase == .signedIn,
              sidebar ? model.sidebarPanel == route : model.sheet == route else { return nil }
        return Self(context: LookupContext(model: model, store: store), route: route, parent: parent,
                    api: ObjectIdentifier(model.api as AnyObject), presentation: presentation,
                    sidebar: sidebar, navigation: model.navigationIntent)
    }
}

struct OtherListPage<Row, Cursor> {
    var rows: [Row]
    var consumed: Int
    var next: Cursor?
    var hasMore: Bool
    var problem: String? = nil
    var reconcile: (@MainActor ([Row]) -> [Row])? = nil
}

@MainActor @Observable
final class OtherListState<Input: Equatable, Row: Identifiable, Cursor: Equatable> where Row.ID == Snowflake {
    enum Status: Equatable { case idle, loading, done, failed(String) }
    struct Snapshot {
        var input: Input?
        var rows: [Row] = []
        var consumed = 0
        var cursor: Cursor?
        var status: Status = .idle
        var more: LookupPageProgress = .finished("")
    }
    private var current = Snapshot()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var load: (@MainActor (Cursor?) async throws -> OtherListPage<Row, Cursor>)?
    @ObservationIgnored private var isCurrent: (@MainActor () -> Bool)?
    @ObservationIgnored private var publish: (@MainActor ([Row]) -> Void)?
    // A client browsing policy, not a Discord service guarantee.
    let positionLimit: Int
    init(positionLimit: Int = 1_000) { self.positionLimit = max(1, positionLimit) }

    func snapshot(for input: Input?) -> Snapshot {
        guard let input, input == current.input else { return Snapshot() }
        return current
    }

    func invalidate() {
        generation = UUID(); requestID = nil
        task?.cancel(); task = nil
        load = nil; isCurrent = nil; publish = nil
        current = Snapshot()
    }

    @discardableResult
    func start(_ input: Input, load: @escaping @MainActor (Cursor?) async throws -> OtherListPage<Row, Cursor>,
               isCurrent: @escaping @MainActor () -> Bool,
               publish: @escaping @MainActor ([Row]) -> Void) -> Task<Void, Never> {
        invalidate()
        self.load = load; self.isCurrent = isCurrent; self.publish = publish
        current = Snapshot(input: input, status: .loading)
        return request(input, initial: true)
    }

    @discardableResult
    func loadMore(_ input: Input) -> Task<Void, Never>? {
        guard input == current.input, current.status == .done, requestID == nil else { return nil }
        switch current.more {
        case .ready, .failed: return request(input, initial: false)
        case .loading, .finished: return nil
        }
    }

    private func request(_ input: Input, initial: Bool) -> Task<Void, Never> {
        let accepted = generation, token = UUID(), cursor = current.cursor
        let load = self.load!, isCurrent = self.isCurrent!, publish = self.publish!
        requestID = token
        if !initial { current.more = .loading }
        let request = Task { @MainActor in
            guard accepts(accepted, token, isCurrent: isCurrent) else { return }
            do {
                let page = try await load(cursor)
                guard accepts(accepted, token, isCurrent: isCurrent) else { return }
                // Reject an entire straddling response before deduplication or
                // any cache publication. Filtering loses raw-position mapping.
                let (nextCount, overflow) = current.consumed.addingReportingOverflow(page.consumed)
                if page.consumed < 0 || overflow || nextCount > positionLimit {
                    finish("The next page exceeds this view's \(positionLimit.formatted()) returned-position limit. Reload Results to start again.")
                    return
                }
                if let problem = page.problem {
                    finish(problem)
                    return
                }
                // A continuation must actually advance, even for a custom API.
                if page.hasMore && (page.next == nil || page.next == cursor) {
                    finish("The page cursor did not advance. Reload Results to try again.")
                    return
                }
                var seen = Set(current.rows.map(\.id))
                let unique = page.rows.filter { seen.insert($0.id).inserted }
                let added = page.reconcile?(unique) ?? unique
                // No suspension between authority check and ALL cache/row writes.
                // Duplicates cannot mutate authors or overwrite known threads.
                publish(added)
                current.rows.append(contentsOf: added)
                current.consumed = nextCount
                current.cursor = page.next ?? cursor
                current.status = .done
                if nextCount >= positionLimit {
                    finish("This view is limited to \(positionLimit.formatted()) returned positions. Reload Results to start again.")
                } else if !page.hasMore {
                    finish("All results returned by these pages are loaded.")
                } else if page.consumed == 0 || added.isEmpty {
                    finish("No new rows were returned. Reload Results to try again.")
                } else {
                    current.more = .ready
                    requestID = nil; self.task = nil
                }
            } catch {
                guard accepts(accepted, token, isCurrent: isCurrent) else { return }
                if initial { current.status = .failed(error.localizedDescription) }
                else { current.more = .failed(error.localizedDescription) }
                requestID = nil; self.task = nil
            }
        }
        task = request
        return request
    }

    private func finish(_ reason: String) {
        current.status = .done; current.more = .finished(reason)
        requestID = nil; task = nil
    }

    private func accepts(_ accepted: UUID, _ token: UUID, isCurrent: () -> Bool) -> Bool {
        guard generation == accepted, requestID == token else { return false }
        guard !Task.isCancelled, isCurrent() else { invalidate(); return false }
        return true
    }
}

/// Production consumers capture immutable API/parent references here; tests
/// exercise these same entry points with held offline loads.
enum OtherListConsumers {
    static func archivedRows(_ rows: [Channel], active: [Channel], store: DiscordStore? = nil) -> [Channel] {
        let ids = Set(active.map(\.id))
        return rows.compactMap { row in
            guard !ids.contains(row.id) else { return nil }
            guard let store else { return row }
            guard let current = store.channel(row.id),
                  current.type == .publicThread, current.parentID == row.parentID,
                  row.guildID == nil || current.guildID == row.guildID,
                  current.threadMetadata?.archived == true else { return nil }
            return current
        }
    }

    static func mentions<I>(_ owner: OtherListState<I, Message, Snowflake>, input: I, api: DiscordAPI,
                            store: DiscordStore, isCurrent: @escaping @MainActor () -> Bool,
                            fetch: (@MainActor (Snowflake?) async throws -> [Message])? = nil) -> Task<Void, Never> {
        owner.start(input, load: { before in
            let rows: [Message]
            if let fetch { rows = try await fetch(before) }
            else { rows = try await api.mentions(limit: 25, before: before) }
            return OtherListPages.mentions(rows, before: before)
        }, isCurrent: isCurrent, publish: { store.remember(messageAuthors: $0) })
    }
    static func archives<I>(_ owner: OtherListState<I, Channel, String>, input: I, api: DiscordAPI,
                            parent: Channel, store: DiscordStore, isCurrent: @escaping @MainActor () -> Bool,
                            fetch: (@MainActor (String?) async throws -> ArchivedThreadPage)? = nil) -> Task<Void, Never> {
        owner.start(input, load: { before in
            let revision = store.channelRevision
            let page: ArchivedThreadPage
            if let fetch { page = try await fetch(before) }
            else { page = try await api.publicArchivedThreads(channel: parent.id, before: before) }
            var result = OtherListPages.archives(page, parent: parent, before: before)
            result.reconcile = { rows in
                rows.compactMap { row in
                    guard store.channelChanged(row.id, since: revision) else { return row }
                    guard let current = store.channel(row.id),
                          OtherListPages.isArchive(current, parent: parent) else { return nil }
                    return current
                }
            }
            return result
        }, isCurrent: isCurrent, publish: { store.remember(threads: $0) })
    }
}

enum InboxLists {
    static func unreadChannels(store: DiscordStore) -> [Channel] {
        store.channels.values.filter { channel in
            (store.mentionCount(channel.id) > 0 || (store.isUnread(channel) && !store.isMuted(channel) && !(channel.guildID.map(store.isMuted(guild:)) ?? false)))
                && (channel.guildID == nil || store.canView(channel))
        }
        .sorted { ($0.lastMessageID ?? 0) > ($1.lastMessageID ?? 0) }

    }
}

/// Integer seconds and normalized decimal digits retain the wire's precision.
nonisolated struct ArchiveTimestamp: Comparable {
    let seconds: Int64
    let fraction: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
        let width = max(lhs.fraction.count, rhs.fraction.count)
        return lhs.fraction.padding(toLength: width, withPad: "0", startingAt: 0) <
            rhs.fraction.padding(toLength: width, withPad: "0", startingAt: 0)
    }
}

/// Validate cursors from raw consumed rows, before filtering or ID deduplication.
/// Archive timestamps are opaque wire strings; parsed dates only validate order.
enum OtherListPages {
    static func mentions(_ rows: [Message], before: Snowflake?) -> OtherListPage<Message, Snowflake> {
        let next = rows.map(\.id).min()
        let problem: String?
        if rows.contains(where: { $0.id.raw == 0 }) || (next != nil && before != nil && next! >= before!) {
            problem = "The mention cursor was invalid or did not advance. Reload Results to try again."
        } else { problem = nil }
        return OtherListPage(rows: rows, consumed: rows.count, next: next,
                             hasMore: rows.count >= 25, problem: problem)
    }

    nonisolated static func archiveDate(_ value: String) -> ArchiveTimestamp? {
        // Support complete RFC3339 calendar timestamps, excluding leap seconds.
        // Foundation formatters may truncate fractions or normalize bad dates.
        let pattern = #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?([Zz]|[+-][0-9]{2}:[0-9]{2})\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func part(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
        guard let year = Int(part(1)), year >= 1,
              let month = Int(part(2)), (1...12).contains(month),
              let day = Int(part(3)),
              let hour = Int(part(4)), hour < 24,
              let minute = Int(part(5)), minute < 60,
              let second = Int(part(6)), second < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1, day <= lengths[month - 1] else { return nil }
        let zone = part(8)
        var offset = 0
        if zone != "Z" && zone != "z" {
            let parts = zone.dropFirst().split(separator: ":")
            guard parts.count == 2, let hours = Int(parts[0]), hours < 24,
                  let minutes = Int(parts[1]), minutes < 60 else { return nil }
            offset = (hours * 60 + minutes) * 60 * (zone.first == "-" ? -1 : 1)
        }
        // Proleptic Gregorian civil date to days since 1970-01-01.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearInEra = adjustedYear - era * 400
        let shiftedMonth = month + (month > 2 ? -3 : 9)
        let dayInYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayInEra = yearInEra * 365 + yearInEra / 4 - yearInEra / 100 + dayInYear
        let days = era * 146097 + dayInEra - 719468
        let seconds = Int64(days) * 86400 + Int64(hour * 3600 + minute * 60 + second - offset)
        var fraction = part(7)
        while fraction.last == "0" { fraction.removeLast() }
        return ArchiveTimestamp(seconds: seconds, fraction: fraction)
    }

    static func isArchive(_ row: Channel, parent: Channel) -> Bool {
        row.type == .publicThread && row.parentID == parent.id &&
        (row.guildID == nil || parent.guildID == nil || row.guildID == parent.guildID) &&
        row.threadMetadata?.archived == true
    }

    static func archives(_ page: ArchivedThreadPage, parent: Channel, before: String?) -> OtherListPage<Channel, String> {
        let rows = page.threads.filter { isArchive($0, parent: parent) }
        let next = page.threads.last?.threadMetadata?.archiveTimestamp
        var problem: String?
        if page.hasMore {
            let dates = page.threads.compactMap { $0.threadMetadata?.archiveTimestamp.flatMap(archiveDate) }
            if dates.count != page.threads.count || dates.isEmpty ||
                zip(dates, dates.dropFirst()).contains(where: { $0 < $1 }) {
                problem = "The archive cursor was missing, invalid or unordered. Reload Results to try again."
            } else if let before {
                if let previous = archiveDate(before), let last = dates.last, last < previous {
                    // Keep the exact raw string, including timezone and precision.
                } else {
                    problem = "The archive cursor did not advance. Reload Results to try again."
                }
            }
        }
        return OtherListPage(rows: rows, consumed: page.threads.count, next: next, hasMore: page.hasMore, problem: problem)
    }
}
