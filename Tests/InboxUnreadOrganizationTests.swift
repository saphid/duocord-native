import XCTest
@testable import DuocordNative

/// Grouping, filtering, sorting and searching the Inbox Unreads tab. The
/// fixture mixes DMs, server channels, a thread, a mention-only channel and
/// rows that must stay ineligible (muted, hidden and muted-server channels).
@MainActor
final class InboxUnreadOrganizationTests: XCTestCase {
    private let me: Snowflake = 1
    private let alpha: Snowflake = 100, beta: Snowflake = 400, mutedServer: Snowflake = 500
    // Alpha
    private let general: Snowflake = 301, prs: Snowflake = 302, mutedChannel: Snowflake = 303
    private let hidden: Snowflake = 304, alerts: Snowflake = 305, thread: Snowflake = 306
    // beta
    private let zeta: Snowflake = 401, apple: Snowflake = 402, betaNews: Snowflake = 403
    // Muted Co
    private let quiet: Snowflake = 501, mutedNews: Snowflake = 502
    // Direct messages
    private let casey: Snowflake = 700, weekend: Snowflake = 701
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func sf(_ seconds: Int) -> Snowflake { Snowflake.at(base.addingTimeInterval(Double(seconds))) }

    private func row(_ id: Snowflake, _ name: String, guild: Snowflake, last: Int, type: ChannelType = .text,
                     parent: Snowflake? = nil) -> Channel {
        Channel(id: id, type: type, guildID: guild, name: name, position: 0, parentID: parent, lastMessageID: sf(last))
    }

    private func server(_ id: Snowflake, _ name: String, _ channels: [Channel], threads: [Channel] = []) -> Guild {
        let viewable = Permission.viewChannel | Permission.readHistory | Permission.sendMessages | Permission.sendInThreads
        let everyone = Role(id: id, name: "@everyone", color: 0, position: 0, permissions: String(viewable))
        var guild = Guild(id: id, name: name, roles: [everyone], channels: channels)
        guild.ownerID = 2
        guild.threads = threads
        return guild
    }

    /// `allRead` marks every row read so the eligible list is empty.
    private func makeStore(allRead: Bool = false) throws -> DiscordStore {
        let store = DiscordStore(notificationClock: { [base] in base.addingTimeInterval(1_000_000) })
        var secret = row(hidden, "secret", guild: alpha, last: 80)
        secret.permissionOverwrites = [PermissionOverwrite(id: alpha, type: 0, allow: "0", deny: String(Permission.viewChannel))]
        let alphaChannels = [row(general, "general", guild: alpha, last: 90), row(prs, "prs", guild: alpha, last: 95),
                             row(mutedChannel, "muted-chan", guild: alpha, last: 50), secret,
                             row(alerts, "alerts", guild: alpha, last: 10)]
        let prThread = row(thread, "pr-7", guild: alpha, last: 60, type: .publicThread, parent: prs)
        let betaChannels = [row(zeta, "zeta", guild: beta, last: 30), row(apple, "Ápple", guild: beta, last: 30),
                            row(betaNews, "news", guild: beta, last: 5)]
        let mutedChannels = [row(quiet, "quiet", guild: mutedServer, last: 40), row(mutedNews, "news", guild: mutedServer, last: 15)]
        let dms = [Channel(id: casey, type: .dm, lastMessageID: sf(70), recipients: [User(id: 9, username: "Casey")]),
                   Channel(id: weekend, type: .groupDM, name: "Weekend", lastMessageID: sf(20),
                           recipients: [User(id: 9, username: "Casey"), User(id: 10, username: "Robin")])]
        let guilds = [server(alpha, "Alpha", alphaChannels, threads: [prThread]), server(beta, "beta", betaChannels),
                      server(mutedServer, "Muted Co", mutedChannels)]
        let all = alphaChannels + [prThread] + betaChannels + mutedChannels + dms
        let mentions: [Snowflake: Int] = allRead ? [:] : [alerts: 2, zeta: 1, mutedNews: 1, weekend: 3]
        // Read rows are read to their latest message; unread rows to the start.
        let readRows: Set<Snowflake> = allRead ? Set(all.map(\.id)) : [general, prs, alerts]
        let states = all.map { channel in
            ReadState(id: channel.id, lastMessageID: readRows.contains(channel.id) ? channel.lastMessageID : sf(1),
                      mentionCount: mentions[channel.id] ?? 0)
        }
        let member = try JSONDecoder().decode(Member.self, from: Data(#"{"user_id":"1","roles":[]}"#.utf8))
        let settings = try [#"{"guild_id":"100","channel_overrides":[{"channel_id":"303","muted":true}]}"#,
                            #"{"guild_id":"500","muted":true}"#]
            .map { try JSONDecoder().decode(UserGuildSettings.self, from: Data($0.utf8)) }
        store.apply(ready: ReadyPayload(user: User(id: me, username: "me"), guilds: guilds, privateChannels: dms, users: [],
                                        mergedMembers: [[member], [member], [member]], readStates: states,
                                        guildSettings: settings, settingsProto: nil))
        return store
    }

    private func organized(_ store: DiscordStore, grouping: InboxUnreadGrouping = .none, filter: InboxUnreadFilter = .all,
                           sort: InboxUnreadSort = .recent, query: String = "") -> InboxUnreadResult {
        InboxLists.organizedUnreads(store: store, organization: InboxUnreadOrganization(grouping: grouping, filter: filter,
                                                                                        sort: sort, query: query))
    }

    private func ids(_ result: InboxUnreadResult) -> [Snowflake] { result.rows.map(\.id) }

    // MARK: Eligibility

    func testOrganizationKeepsUnreadEligibility() throws {
        let store = try makeStore()
        let eligible = Set(InboxLists.unreadChannels(store: store).map(\.id))
        XCTAssertEqual(eligible, [alerts, thread, zeta, apple, betaNews, mutedNews, casey, weekend],
                       "mentions keep a muted server's channel; muted, hidden and muted-server unread rows stay out")
        for grouping in InboxUnreadGrouping.allCases {
            for sort in InboxUnreadSort.allCases {
                let result = organized(store, grouping: grouping, sort: sort)
                XCTAssertEqual(result.eligible, 8)
                XCTAssertEqual(Set(ids(result)), eligible, "\(grouping) \(sort) must neither drop nor add rows")
                XCTAssertEqual(ids(result).count, 8, "no row appears twice")
            }
        }
        for filter in InboxUnreadFilter.allCases {
            XCTAssertTrue(Set(ids(organized(store, filter: filter))).isSubset(of: eligible), "\(filter) only narrows")
        }
        // Searching for an ineligible row's name never brings it back.
        for name in ["muted-chan", "secret", "quiet", "general"] {
            let result = organized(store, query: name)
            XCTAssertTrue(result.isHiddenByOrganization, name)
            XCTAssertTrue(result.sections.isEmpty, name)
        }
    }

    // MARK: Sorting

    func testRecentActivityIsTheDefaultAndBreaksTiesByChannel() throws {
        let store = try makeStore()
        XCTAssertEqual(InboxUnreadOrganization.standard.grouping, .server)
        XCTAssertEqual(InboxUnreadOrganization.standard.filter, .all)
        XCTAssertEqual(InboxUnreadOrganization.standard.sort, .recent)
        XCTAssertEqual(InboxUnreadOrganization.standard.query, "")
        // zeta and Ápple share their latest activity; the newer channel ID leads.
        XCTAssertEqual(ids(organized(store, sort: .recent)), [casey, thread, apple, zeta, weekend, mutedNews, alerts, betaNews])
        XCTAssertEqual(ids(organized(store, sort: .oldest)), [betaNews, alerts, mutedNews, weekend, zeta, apple, thread, casey])
    }

    func testNameSortIsLocalizedAndBreaksTiesByServer() throws {
        let store = try makeStore()
        // "Ápple" sorts with A; the two "news" channels order by server name.
        XCTAssertEqual(ids(organized(store, sort: .name)), [alerts, apple, casey, betaNews, mutedNews, thread, weekend, zeta])
    }

    func testMostMentionsFallsBackToRecentActivity() throws {
        let store = try makeStore()
        XCTAssertEqual(ids(organized(store, sort: .mentions)), [weekend, alerts, zeta, mutedNews, casey, thread, apple, betaNews])
    }

    func testOrderDoesNotDependOnInputOrder() throws {
        let store = try makeStore()
        let eligible = InboxLists.unreadChannels(store: store)
        for sort in InboxUnreadSort.allCases {
            for grouping in InboxUnreadGrouping.allCases {
                let organization = InboxUnreadOrganization(grouping: grouping, sort: sort)
                let forward = InboxLists.organize(eligible, store: store, organization: organization)
                let reversed = InboxLists.organize(eligible.reversed(), store: store, organization: organization)
                let shuffled = InboxLists.organize(eligible.sorted { $0.id.raw % 3 < $1.id.raw % 3 }, store: store,
                                                   organization: organization)
                XCTAssertEqual(forward, reversed, "\(grouping) \(sort)")
                XCTAssertEqual(forward, shuffled, "\(grouping) \(sort)")
            }
        }
    }

    // MARK: Grouping

    func testServerGroupingPutsDirectMessagesFirst() throws {
        let store = try makeStore()
        let result = organized(store, grouping: .server, sort: .recent)
        XCTAssertEqual(result.sections.map(\.kind), [.directMessages, .server(alpha), .server(beta), .server(mutedServer)])
        XCTAssertEqual(result.sections.map(\.title), ["Direct Messages", "Alpha", "beta", "Muted Co"])
        XCTAssertEqual(result.sections.map { $0.rows.map(\.id) },
                       [[casey, weekend], [thread, alerts], [apple, zeta, betaNews], [mutedNews]])
    }

    func testServerGroupingFollowsTheChosenSort() throws {
        let store = try makeStore()
        let oldest = organized(store, grouping: .server, sort: .oldest)
        XCTAssertEqual(oldest.sections.map(\.kind), [.directMessages, .server(beta), .server(alpha), .server(mutedServer)],
                       "servers follow their first row; DMs still lead")
        XCTAssertEqual(oldest.sections.first?.rows.map(\.id), [weekend, casey])
        let byName = organized(store, grouping: .server, sort: .name)
        XCTAssertEqual(byName.sections.map(\.title), ["Direct Messages", "Alpha", "beta", "Muted Co"],
                       "a name sort orders servers by name")
        XCTAssertEqual(byName.sections.map { $0.rows.map(\.id) },
                       [[casey, weekend], [alerts, thread], [apple, betaNews, zeta], [mutedNews]])
        let mentions = organized(store, grouping: .server, sort: .mentions)
        XCTAssertEqual(mentions.sections.map(\.kind), [.directMessages, .server(alpha), .server(beta), .server(mutedServer)])
        XCTAssertEqual(mentions.sections[2].rows.map(\.id), [zeta, apple, betaNews])
    }

    func testNoGroupingIsOneUntitledSection() throws {
        let result = organized(try makeStore(), grouping: .none)
        XCTAssertEqual(result.sections.count, 1)
        XCTAssertEqual(result.sections.first?.kind, .all)
        XCTAssertNil(result.sections.first?.title)
    }

    // MARK: Filters and search

    func testFilters() throws {
        let store = try makeStore()
        XCTAssertEqual(ids(organized(store, filter: .mentions)), [zeta, weekend, mutedNews, alerts])
        XCTAssertEqual(ids(organized(store, filter: .directMessages)), [casey, weekend])
        XCTAssertEqual(ids(organized(store, filter: .servers)), [thread, apple, zeta, mutedNews, alerts, betaNews],
                       "server channels include their threads")
        XCTAssertEqual(ids(organized(store, filter: .threads)), [thread])
        let dmsGrouped = organized(store, grouping: .server, filter: .directMessages)
        XCTAssertEqual(dmsGrouped.sections.map(\.kind), [.directMessages])
        let threadsGrouped = organized(store, grouping: .server, filter: .threads)
        XCTAssertEqual(threadsGrouped.sections.map(\.kind), [.server(alpha)], "empty sections are left out")
    }

    func testSearchMatchesConversationParentAndServerNames() throws {
        let store = try makeStore()
        XCTAssertEqual(ids(organized(store, query: "casey")), [casey, weekend], "a group DM matches a member's name")
        XCTAssertEqual(ids(organized(store, query: "WEEKEND")), [weekend])
        XCTAssertEqual(ids(organized(store, query: "alpha")), [thread, alerts], "server names match")
        XCTAssertEqual(ids(organized(store, query: "prs")), [thread], "a thread matches its parent channel")
        XCTAssertEqual(ids(organized(store, query: "apple")), [apple], "matching ignores diacritics")
        XCTAssertEqual(ids(organized(store, query: "  news \n")), [mutedNews, betaNews], "surrounding whitespace is ignored")
        XCTAssertEqual(ids(organized(store, query: "   ")).count, 8, "blank search hides nothing")
        XCTAssertEqual(ids(organized(store, filter: .mentions, query: "news")), [mutedNews], "filter and search combine")
    }

    // MARK: Empty states

    func testNoMatchIsDistinctFromAllCaughtUp() throws {
        let store = try makeStore()
        let noMatch = organized(store, grouping: .server, filter: .threads, query: "casey")
        XCTAssertEqual(noMatch.eligible, 8)
        XCTAssertTrue(noMatch.sections.isEmpty)
        XCTAssertTrue(noMatch.isHiddenByOrganization)
        XCTAssertFalse(noMatch.isCaughtUp)

        let caughtUp = try makeStore(allRead: true)
        XCTAssertTrue(InboxLists.unreadChannels(store: caughtUp).isEmpty)
        for filter in InboxUnreadFilter.allCases {
            let result = organized(caughtUp, grouping: .server, filter: filter, query: "casey")
            XCTAssertTrue(result.isCaughtUp, "\(filter): nothing unread is caught up, not hidden")
            XCTAssertFalse(result.isHiddenByOrganization)
        }
    }

    func testOrganizationStateReportsWhatNarrowsTheList() {
        var organization = InboxUnreadOrganization.standard
        XCTAssertFalse(organization.narrows)
        XCTAssertFalse(organization.isCustomized)
        organization.sort = .name
        organization.grouping = .none
        XCTAssertFalse(organization.narrows, "grouping and sort never hide rows")
        XCTAssertTrue(organization.isCustomized)
        organization = .standard
        organization.query = "  "
        XCTAssertFalse(organization.narrows)
        organization.query = "news"
        XCTAssertTrue(organization.narrows)
        organization = .standard
        organization.filter = .threads
        XCTAssertTrue(organization.narrows)
    }

    /// Saved preferences use stable raw values; changing them would reset users' choices.
    func testSavedPreferenceValuesAreStable() {
        XCTAssertEqual(InboxUnreadGrouping.allCases.map(\.rawValue), ["none", "server"])
        XCTAssertEqual(InboxUnreadFilter.allCases.map(\.rawValue), ["all", "mentions", "directMessages", "servers", "threads"])
        XCTAssertEqual(InboxUnreadSort.allCases.map(\.rawValue), ["recent", "oldest", "name", "mentions"])
        XCTAssertEqual([InboxUnreadPreferenceKey.grouping, InboxUnreadPreferenceKey.filter, InboxUnreadPreferenceKey.sort],
                       ["inbox.unreads.grouping", "inbox.unreads.filter", "inbox.unreads.sort"])
    }
}
