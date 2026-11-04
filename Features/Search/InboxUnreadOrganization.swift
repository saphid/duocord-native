import SwiftUI

/// How the Inbox Unreads tab groups its rows. Direct messages always form
/// their own section when grouped by server.
enum InboxUnreadGrouping: String, CaseIterable, Identifiable {
    case none, server
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "None"
        case .server: "Server"
        }
    }
}

/// Which unread conversations the Unreads tab shows. Filters only narrow the
/// eligible list; they never change what counts as unread.
enum InboxUnreadFilter: String, CaseIterable, Identifiable {
    case all, mentions, directMessages, servers, threads
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .mentions: "Mentions"
        case .directMessages: "Direct Messages"
        case .servers: "Servers"
        case .threads: "Threads"
        }
    }
    var symbol: String {
        switch self {
        case .all: "tray"
        case .mentions: "at"
        case .directMessages: "bubble.left.and.bubble.right"
        case .servers: "server.rack"
        case .threads: "bubble.left.fill"
        }
    }

    func includes(_ channel: Channel, mentions: Int) -> Bool {
        switch self {
        case .all: true
        case .mentions: mentions > 0
        case .directMessages: channel.type.isPrivate
        // Server channels include their threads, as server grouping does.
        case .servers: !channel.type.isPrivate
        case .threads: channel.type.isThread
        }
    }
}

enum InboxUnreadSort: String, CaseIterable, Identifiable {
    case recent, oldest, name, mentions
    var id: Self { self }
    var title: String {
        switch self {
        case .recent: "Recent Activity"
        case .oldest: "Oldest Activity"
        case .name: "Name"
        case .mentions: "Most Mentions"
        }
    }
}

/// The Unreads tab's grouping, filter, sort and name search.
struct InboxUnreadOrganization: Equatable {
    var grouping: InboxUnreadGrouping = .server
    var filter: InboxUnreadFilter = .all
    var sort: InboxUnreadSort = .recent
    var query = ""

    static let standard = InboxUnreadOrganization()

    /// The search text that applies, without surrounding whitespace.
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// True when the filter or search can hide unread rows.
    var narrows: Bool { filter != .all || !trimmedQuery.isEmpty }
    /// True when any choice differs from the defaults.
    var isCustomized: Bool { grouping != .server || filter != .all || sort != .recent }

    /// Spoken summary of the current choices.
    var summary: String {
        var parts = ["Grouped by \(grouping == .none ? "nothing" : "server")", "Showing \(filter.title.lowercased())",
                     "Sorted by \(sort.title.lowercased())"]
        if !trimmedQuery.isEmpty { parts.append("Matching \(trimmedQuery)") }
        return parts.joined(separator: ", ")
    }
}

/// One section of organized unread rows. Ungrouped lists have one untitled section.
struct InboxUnreadSection: Identifiable, Equatable {
    enum Kind: Hashable {
        case all, directMessages, server(Snowflake)
    }
    let kind: Kind
    let title: String?
    let rows: [Channel]
    var id: Kind { kind }
}

/// The organized Unreads tab. `eligible` counts every unread row before the
/// filter and search, so an empty result can tell "caught up" from "hidden".
struct InboxUnreadResult: Equatable {
    let eligible: Int
    let sections: [InboxUnreadSection]

    var rows: [Channel] { sections.flatMap(\.rows) }
    var isCaughtUp: Bool { eligible == 0 }
    var isHiddenByOrganization: Bool { eligible > 0 && sections.isEmpty }
}

extension InboxLists {
    /// Unread eligibility comes only from `unreadChannels`; organization then
    /// filters, searches, sorts and groups those rows.
    static func organizedUnreads(store: DiscordStore, organization: InboxUnreadOrganization) -> InboxUnreadResult {
        organize(unreadChannels(store: store), store: store, organization: organization)
    }

    static func organize(_ eligible: [Channel], store: DiscordStore, organization: InboxUnreadOrganization) -> InboxUnreadResult {
        let query = organization.trimmedQuery
        let rows = eligible
            .map { InboxUnreadSortKey($0, store: store) }
            .filter { organization.filter.includes($0.channel, mentions: $0.mentions) && $0.matches(query) }
            .sorted { $0.precedes($1, by: organization.sort) }
        guard !rows.isEmpty else { return InboxUnreadResult(eligible: eligible.count, sections: []) }
        switch organization.grouping {
        case .none:
            return InboxUnreadResult(eligible: eligible.count,
                                     sections: [InboxUnreadSection(kind: .all, title: nil, rows: rows.map(\.channel))])
        case .server:
            return InboxUnreadResult(eligible: eligible.count, sections: serverSections(rows, sort: organization.sort))
        }
    }

    /// Direct messages come first, like the server rail. Servers follow their
    /// first row in the chosen order; a name sort orders servers by name.
    private static func serverSections(_ rows: [InboxUnreadSortKey], sort: InboxUnreadSort) -> [InboxUnreadSection] {
        var order: [InboxUnreadSection.Kind] = []
        var grouped: [InboxUnreadSection.Kind: [InboxUnreadSortKey]] = [:]
        for row in rows {
            let kind = row.section
            if grouped[kind] == nil { order.append(kind) }
            grouped[kind, default: []].append(row)
        }
        func title(_ kind: InboxUnreadSection.Kind) -> String {
            switch kind {
            case .directMessages: "Direct Messages"
            case .server: grouped[kind]?.first?.guildName ?? "Unknown Server"
            case .all: ""
            }
        }
        var servers = order.filter { $0 != .directMessages }
        if sort == .name {
            servers.sort { lhs, rhs in
                let order = title(lhs).localizedStandardCompare(title(rhs))
                if order != .orderedSame { return order == .orderedAscending }
                guard case .server(let left) = lhs, case .server(let right) = rhs else { return false }
                return left < right
            }
        }
        let kinds = (grouped[.directMessages] == nil ? [] : [InboxUnreadSection.Kind.directMessages]) + servers
        return kinds.map { InboxUnreadSection(kind: $0, title: title($0), rows: grouped[$0, default: []].map(\.channel)) }
    }
}

/// Values an unread row is filtered, sorted and grouped by, read once.
private struct InboxUnreadSortKey {
    let channel: Channel
    let title: String
    let parentName: String?
    let guildName: String?
    /// A direct message's members, so a named group DM matches its people.
    let memberNames: [String]
    let mentions: Int
    let activity: Snowflake

    init(_ channel: Channel, store: DiscordStore) {
        self.channel = channel
        title = InboxRowLocation.describe(channel, store: store).title
        parentName = channel.type.isThread ? channel.parentID.flatMap { store.channel($0) }.map(store.channelName) : nil
        guildName = channel.type.isPrivate ? nil : channel.guildID.flatMap { store.guilds[$0]?.name }
        memberNames = channel.type.isPrivate ? store.recipients(of: channel).map(\.displayName) : []
        mentions = store.mentionCount(channel.id)
        activity = channel.lastMessageID ?? 0
    }

    var section: InboxUnreadSection.Kind {
        if channel.type.isPrivate { return .directMessages }
        return .server(channel.guildID ?? 0)
    }

    /// Case- and diacritic-insensitive match on the conversation, a direct
    /// message's members, a thread's parent channel or the server name.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return ([title, parentName, guildName].compactMap { $0 } + memberNames).contains { name in
            name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// A strict total order: every sort ends with the channel ID so equal
    /// activity, names or mention counts never reorder between updates.
    func precedes(_ other: Self, by sort: InboxUnreadSort) -> Bool {
        func newer() -> Bool {
            activity != other.activity ? activity > other.activity : channel.id > other.channel.id
        }
        switch sort {
        case .recent:
            return newer()
        case .oldest:
            return activity != other.activity ? activity < other.activity : channel.id < other.channel.id
        case .name:
            let order = title.localizedStandardCompare(other.title)
            if order != .orderedSame { return order == .orderedAscending }
            let place = (guildName ?? "").localizedStandardCompare(other.guildName ?? "")
            if place != .orderedSame { return place == .orderedAscending }
            return channel.id < other.channel.id
        case .mentions:
            return mentions != other.mentions ? mentions > other.mentions : newer()
        }
    }
}

/// Saved Unreads tab choices. The search text is not saved: it can name
/// account-specific servers and conversations.
enum InboxUnreadPreferenceKey {
    static let grouping = "inbox.unreads.grouping"
    static let filter = "inbox.unreads.filter"
    static let sort = "inbox.unreads.sort"
}

/// The Unreads tab's compact controls: a name search and one menu holding
/// grouping, filter and sort. Shared by the sidebar panel and the sheet.
struct InboxUnreadControls: View {
    @Binding var organization: InboxUnreadOrganization
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.textMuted)
                TextField("Search Unreads", text: $organization.query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityIdentifier("inboxUnreadSearch")
                if !organization.query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { organization.query = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            // A translucent fill reads on the sheet's glass and the sidebar page alike.
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Menu {
                Picker(selection: $organization.grouping) {
                    ForEach(InboxUnreadGrouping.allCases) { Text($0.title).tag($0) }
                } label: { Label("Group By", systemImage: "square.stack.3d.up") }
                    .pickerStyle(.menu)
                Picker(selection: $organization.filter) {
                    ForEach(InboxUnreadFilter.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: { Label("Show", systemImage: "line.3.horizontal.decrease") }
                    .pickerStyle(.menu)
                Picker(selection: $organization.sort) {
                    ForEach(InboxUnreadSort.allCases) { Text($0.title).tag($0) }
                } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
                    .pickerStyle(.menu)
                if organization.isCustomized || !organization.query.isEmpty {
                    Divider()
                    Button("Reset", systemImage: "arrow.counterclockwise") { reset() }
                }
            } label: {
                Image(systemName: organization.narrows || organization.isCustomized
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Organize Unreads")
            .accessibilityValue(organization.summary)
            .accessibilityIdentifier("inboxUnreadOrganize")
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
