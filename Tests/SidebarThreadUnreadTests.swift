import XCTest
@testable import DuocordNative

/// The sidebar projection ChannelList draws, the server rail badge and the
/// Inbox unread list, driven through READY and gateway dispatches.
@MainActor
final class SidebarThreadUnreadTests: XCTestCase {
    private let me: Snowflake = 1
    private let other = User(id: 6, username: "pr-bot")
    private let guild: Snowflake = 100
    private let category: Snowflake = 200
    private let prs: Snowflake = 300
    private let general: Snowflake = 301
    private let secret: Snowflake = 302
    private let forum: Snowflake = 303
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    /// A snowflake created `seconds` after the fixture's base time.
    private func sf(_ seconds: Int) -> Snowflake { Snowflake.at(base.addingTimeInterval(Double(seconds))) }
    private func stamp(_ seconds: Int) -> String {
        ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(seconds)))
    }

    private func channel(_ id: Snowflake, _ type: ChannelType, _ name: String, position: Int, parent: Snowflake?) -> Channel {
        Channel(id: id, type: type, guildID: guild, name: name, position: position, parentID: parent, lastMessageID: sf(1))
    }

    private func thread(_ n: Int, parent: Snowflake? = nil, last: Int? = nil, archived: Bool = false,
                        joined: Bool = false, joinedAt: Int? = nil) -> Channel {
        var row = Channel(id: sf(n), type: .publicThread, guildID: guild, name: "pr-\(n)", parentID: parent ?? prs,
                          lastMessageID: last.map(sf))
        row.threadMetadata = ThreadMetadata(archived: archived, locked: false)
        if joined || joinedAt != nil { row.member = ThreadMemberRef(joinTimestamp: joinedAt.map(stamp)) }
        return row
    }

    private func read(_ channel: Channel, mentions: Int = 0) -> ReadState {
        ReadState(id: channel.id, lastMessageID: channel.lastMessageID, mentionCount: mentions)
    }

    private func store(threads: [Channel], readStates: [ReadState], settings: String? = nil) throws -> DiscordStore {
        let store = DiscordStore(notificationClock: { [base] in base.addingTimeInterval(1_000_000) })
        let viewable = Permission.viewChannel | Permission.readHistory | Permission.sendMessages | Permission.sendInThreads
        let everyone = Role(id: guild, name: "@everyone", color: 0, position: 0, permissions: String(viewable))
        var hidden = channel(secret, .text, "secret", position: 2, parent: category)
        hidden.permissionOverwrites = [PermissionOverwrite(id: guild, type: 0, allow: "0", deny: String(Permission.viewChannel))]
        let channels = [channel(category, .category, "Work", position: 0, parent: nil),
                        channel(prs, .text, "prs", position: 0, parent: category),
                        channel(general, .text, "general", position: 1, parent: category),
                        hidden,
                        channel(forum, .forum, "ideas", position: 3, parent: category)]
        var server = Guild(id: guild, name: "T3Code", roles: [everyone], channels: channels)
        server.ownerID = 2
        server.threads = threads
        let member = try JSONDecoder().decode(Member.self, from: Data(#"{"user_id":"1","roles":[]}"#.utf8))
        let guildSettings = try settings.map { [try JSONDecoder().decode(UserGuildSettings.self, from: Data($0.utf8))] } ?? []
        // Parent channels are read unless a test says otherwise.
        let parents = channels.filter { $0.type != .category }.map { read($0) }
        store.apply(ready: ReadyPayload(user: User(id: me, username: "me"), guilds: [server], privateChannels: [], users: [],
                                        mergedMembers: [[member]], readStates: parents + readStates,
                                        guildSettings: guildSettings, settingsProto: nil))
        return store
    }

    private func entry(_ store: DiscordStore, _ id: Snowflake, collapsed: Set<Snowflake> = [], expanded: Set<Snowflake> = [],
                       selected: Snowflake? = nil) -> DiscordStore.ChannelListEntry? {
        store.channelList(for: guild, collapsed: collapsed, expanded: expanded, selected: selected)
            .flatMap(\.entries).first { $0.channel.id == id }
    }

    private func dispatch(_ store: DiscordStore, _ name: String, _ json: String) {
        store.handle(GatewayDispatch(name: name, data: Data(("{\"d\":" + json + "}").utf8)))
    }

    private func incoming(_ store: DiscordStore, _ message: Message) throws {
        struct Envelope: Encodable { var d: Message }
        store.handle(GatewayDispatch(name: "MESSAGE_CREATE", data: try JSONEncoder().encode(Envelope(d: message))))
    }

    // MARK: Discoverability

    func testEveryActiveThreadBeyondFiveIsDiscoverable() throws {
        let threads = (1...120).map { thread($0, last: $0 + 1000) }
        let store = try store(threads: threads, readStates: threads.map { read($0) })
        let collapsed = try XCTUnwrap(entry(store, prs))
        XCTAssertEqual(collapsed.threads.map(\.id), (116...120).reversed().map(sf))
        XCTAssertEqual(collapsed.hiddenThreads, 115, "the remaining threads must be reachable from the parent")
        let expanded = try XCTUnwrap(entry(store, prs, expanded: [prs]))
        XCTAssertEqual(expanded.threads.map(\.id), (1...120).reversed().map(sf))
        XCTAssertEqual(expanded.hiddenThreads, 0)
        XCTAssertEqual(store.threads(in: prs).count, 120)
    }

    func testForumPostsAreListedUnderTheirForum() throws {
        let posts = [thread(1, parent: forum, last: 1001), thread(2, parent: forum, last: 1002)]
        let store = try store(threads: posts, readStates: posts.map { read($0) })
        XCTAssertEqual(entry(store, forum)?.threads.map(\.id), [sf(2), sf(1)])
    }

    func testEqualActivityOrdersByNewestThreadDeterministically() throws {
        // Two threads share their latest message; a third has none and sorts by its own ID.
        var tied = [thread(1, last: 50), thread(2, last: 50), thread(50)]
        for _ in 0..<2 {
            let store = try store(threads: tied, readStates: tied.map { read($0) })
            XCTAssertEqual(entry(store, prs)?.threads.map(\.id), [sf(50), sf(2), sf(1)])
            XCTAssertEqual(store.threads(in: prs).map(\.id), [sf(50), sf(2), sf(1)])
            tied.reverse()
        }
    }

    func testUnreadAndMentionedThreadsBeyondTheRecentFewStayVisible() throws {
        let quiet = (10...29).map { thread($0, last: $0 + 1000) }
        let unread = thread(1, last: 900), mentioned = thread(2, last: 901)
        let store = try store(threads: quiet + [unread, mentioned],
                              readStates: quiet.map { read($0) } + [ReadState(id: unread.id, lastMessageID: sf(800), mentionCount: 0),
                                                                    read(mentioned, mentions: 2)])
        let row = try XCTUnwrap(entry(store, prs))
        XCTAssertEqual(row.threads.map(\.id), (25...29).reversed().map(sf) + [sf(2), sf(1)])
        XCTAssertEqual(row.hiddenThreads, 15)
        XCTAssertEqual(row.rollup, DiscordStore.ThreadRollup(unreadThreads: 1, mentions: 2, mentionThreads: 1))
    }

    // MARK: Missing read state

    func testJoinedThreadWithoutReadStateUsesItsJoinTime() throws {
        let joinedBefore = thread(1, last: 20, joinedAt: 10)
        let joinedAfter = thread(2, last: 20, joinedAt: 30)
        let notJoined = thread(3, last: 20)
        let joinedNoStamp = thread(4, last: 20, joined: true)
        let store = try store(threads: [joinedBefore, joinedAfter, notJoined, joinedNoStamp], readStates: [])
        XCTAssertTrue(store.isUnread(joinedBefore))
        XCTAssertFalse(store.isUnread(joinedAfter))
        XCTAssertFalse(store.isUnread(notJoined), "unjoined threads do not track unread, as in Discord")
        XCTAssertTrue(store.isUnread(joinedNoStamp), "a join without a timestamp falls back to thread creation")
        XCTAssertEqual(entry(store, prs)?.rollup.unreadThreads, 2)
        XCTAssertTrue(store.badge(for: guild).unread)
        let inbox = Set(InboxLists.unreadChannels(store: store).map(\.id))
        XCTAssertEqual(inbox, [joinedBefore.id, joinedNoStamp.id])

        // Joining live records the join time the guess uses.
        dispatch(store, "THREAD_MEMBER_UPDATE", #"{"id":"\#(notJoined.id)","user_id":"1","guild_id":"100","join_timestamp":"\#(stamp(5))"}"#)
        XCTAssertTrue(store.isUnread(try XCTUnwrap(store.channel(notJoined.id))))
        XCTAssertEqual(entry(store, prs)?.rollup.unreadThreads, 3)
    }

    // MARK: Archived and selected

    func testArchivedThreadWithPendingMentionsStaysDiscoverableAndCounted() throws {
        let archivedMention = thread(1, last: 100, archived: true)
        let archivedQuiet = thread(2, last: 101, archived: true)
        let active = thread(3, last: 102)
        let store = try store(threads: [archivedMention, archivedQuiet, active],
                              readStates: [read(archivedMention, mentions: 4), read(archivedQuiet), read(active)])
        XCTAssertEqual(entry(store, prs)?.threads.map(\.id), [active.id, archivedMention.id])
        XCTAssertEqual(entry(store, prs)?.rollup.mentions, 4)
        XCTAssertEqual(store.badge(for: guild).mentions, 4)
        XCTAssertEqual(entry(store, prs, selected: archivedQuiet.id)?.threads.map(\.id), [active.id, archivedQuiet.id, archivedMention.id])
        XCTAssertFalse(store.threads(in: prs).contains { $0.threadMetadata?.archived == true })
    }

    func testCollapsedCategoryKeepsParentsOfUnreadAndSelectedThreads() throws {
        let unread = thread(1, last: 100, joinedAt: 0)
        let quiet = thread(2, last: 101)
        let open = thread(3, parent: general, last: 102)
        let store = try store(threads: [unread, quiet, open], readStates: [read(quiet), read(open)])
        let sections = store.channelList(for: guild, collapsed: [category], selected: open.id)
        XCTAssertEqual(sections.map(\.collapsed), [true])
        let entries = sections.flatMap(\.entries)
        XCTAssertEqual(entries.map(\.channel.id), [prs, general])
        XCTAssertEqual(entries.first?.threads.map(\.id), [unread.id])
        XCTAssertEqual(entries.first?.rollup.unreadThreads, 1)
        XCTAssertEqual(entries.last?.threads.map(\.id), [open.id])
        XCTAssertTrue(entries.allSatisfy { $0.hiddenThreads == 0 && !$0.showsVoice })
    }

    // MARK: Server rollup

    func testServerBadgeCountsEachTraceableThreadOnceAndSkipsInaccessible() throws {
        let active = thread(1, last: 100)
        let archived = thread(2, last: 101, archived: true)
        let denied = thread(3, parent: secret, last: 102)
        let orphan = thread(4, parent: 999, last: 103)
        var parentMentions = channel(prs, .text, "prs", position: 0, parent: category)
        parentMentions.lastMessageID = sf(1)
        let store = try store(threads: [active, archived, denied, orphan],
                              readStates: [read(active, mentions: 3), read(archived, mentions: 4), read(denied, mentions: 50),
                                           read(orphan, mentions: 7), read(parentMentions, mentions: 2)])
        let badge = store.badge(for: guild)
        XCTAssertEqual(badge.mentions, 16, "own 2 + active 3 + archived 4 + unresolved-parent thread 7; denied threads excluded")
        let rows = store.channelList(for: guild).flatMap(\.entries)
        XCTAssertEqual(rows.reduce(0) { $0 + store.mentionCount($1.channel.id) + $1.rollup.mentions }, badge.mentions,
                       "every rail mention traces to a sidebar row")
        XCTAssertNil(rows.first { $0.channel.id == secret })
        XCTAssertNotNil(rows.first { $0.channel.id == orphan.id }, "unresolved activity still needs a reachable metadata row")
        XCTAssertEqual(entry(store, prs)?.rollup, DiscordStore.ThreadRollup(unreadThreads: 0, mentions: 7, mentionThreads: 2))
    }

    func testMutesSilenceUnreadButKeepMentions() throws {
        let unread = thread(1, last: 100, joinedAt: 0)
        let threads = [unread]
        let states = [ReadState(id: unread.id, lastMessageID: sf(50), mentionCount: 1)]

        let plain = try store(threads: threads, readStates: states)
        XCTAssertEqual(entry(plain, prs)?.rollup, DiscordStore.ThreadRollup(unreadThreads: 1, mentions: 1, mentionThreads: 1))
        XCTAssertEqual(plain.badge(for: guild), DiscordStore.GuildBadge(unread: true, mentions: 1))

        let parentMuted = try store(threads: threads, readStates: states,
                                    settings: #"{"guild_id":"100","channel_overrides":[{"channel_id":"300","muted":true}]}"#)
        XCTAssertEqual(entry(parentMuted, prs)?.rollup, DiscordStore.ThreadRollup(unreadThreads: 0, mentions: 1, mentionThreads: 1))
        XCTAssertEqual(parentMuted.badge(for: guild), DiscordStore.GuildBadge(unread: false, mentions: 1))

        var mutedThread = unread
        mutedThread.member?.muted = true
        let threadMuted = try store(threads: [mutedThread], readStates: states)
        XCTAssertEqual(entry(threadMuted, prs)?.rollup.unreadThreads, 0)
        XCTAssertEqual(threadMuted.badge(for: guild), DiscordStore.GuildBadge(unread: false, mentions: 1))

        let guildMuted = try store(threads: threads, readStates: states, settings: #"{"guild_id":"100","muted":true}"#)
        XCTAssertEqual(guildMuted.badge(for: guild), DiscordStore.GuildBadge(unread: false, mentions: 1))
    }

    // MARK: Live events

    func testLiveThreadCreateUpdateAndReadAckClearEveryLevel() throws {
        let older = (10...15).map { thread($0, last: $0 + 100) }
        let store = try store(threads: older, readStates: older.map { read($0) })
        let id = sf(500), messageID = sf(600)
        dispatch(store, "THREAD_CREATE", #"{"id":"\#(id)","type":11,"guild_id":"100","parent_id":"300","name":"pr-new","thread_metadata":{"archived":false}}"#)
        try incoming(store, Message(id: messageID, channelID: id, guildID: guild, author: other,
                                    content: "review requested", timestamp: "", mentions: [User(id: me, username: "me")]))
        var row = try XCTUnwrap(entry(store, prs))
        XCTAssertEqual(row.threads.first?.id, id, "the newest PR thread leads the list")
        XCTAssertEqual(row.rollup, DiscordStore.ThreadRollup(unreadThreads: 1, mentions: 1, mentionThreads: 1))
        XCTAssertEqual(store.badge(for: guild), DiscordStore.GuildBadge(unread: true, mentions: 1))
        XCTAssertTrue(InboxLists.unreadChannels(store: store).contains { $0.id == id })

        // A partial update without guild_id keeps the thread in its server.
        dispatch(store, "THREAD_UPDATE", #"{"id":"\#(id)","type":11,"parent_id":"300","name":"pr-new renamed","thread_metadata":{"archived":false}}"#)
        XCTAssertEqual(store.channel(id)?.guildID, guild)
        XCTAssertEqual(store.channel(id)?.lastMessageID, messageID)
        row = try XCTUnwrap(entry(store, prs))
        XCTAssertEqual(row.threads.first?.name, "pr-new renamed")
        XCTAssertEqual(store.badge(for: guild).mentions, 1)

        dispatch(store, "MESSAGE_ACK", #"{"channel_id":"\#(id)","message_id":"\#(messageID)","mention_count":0,"version":7}"#)
        XCTAssertFalse(store.isUnread(try XCTUnwrap(store.channel(id))))
        XCTAssertEqual(entry(store, prs)?.rollup, DiscordStore.ThreadRollup())
        XCTAssertEqual(store.badge(for: guild), DiscordStore.GuildBadge(unread: false, mentions: 0))
        XCTAssertFalse(InboxLists.unreadChannels(store: store).contains { $0.id == id })
    }

    // MARK: Parent row

    /// What ChannelList draws for a parent row and the thread rows under it.
    private func badges(_ store: DiscordStore, _ row: DiscordStore.ChannelListEntry) -> (parent: ChannelRow.Badge, threads: [Snowflake: ChannelRow.Badge]) {
        (ChannelRow.Badge(channel: row.channel, store: store),
         Dictionary(uniqueKeysWithValues: row.threads.map { ($0.id, ChannelRow.Badge(channel: $0, store: store)) }))
    }

    func testReadParentRowDoesNotInheritThreadUnreadOrMentions() throws {
        let unread = thread(1, last: 100, joinedAt: 0)
        let mentioned = thread(2, last: 101)
        let store = try store(threads: [unread, mentioned],
                              readStates: [ReadState(id: mentioned.id, lastMessageID: sf(50), mentionCount: 2)])
        XCTAssertFalse(store.isUnread(try XCTUnwrap(store.channel(prs))), "fixture: the parent itself is read")

        for collapsed in [Set<Snowflake>(), [category]] {
            let row = try XCTUnwrap(entry(store, prs, collapsed: collapsed))
            let (parent, threads) = badges(store, row)
            XCTAssertFalse(parent.unread, "a read parent is not styled unread by its threads (collapsed: \(collapsed))")
            XCTAssertEqual(parent.mentions, 0, "thread mentions are badged on the thread row, not repeated on the parent")
            XCTAssertEqual(parent.accessibilityValue, "", "a read parent is not announced with its threads' unread state")

            // Each unread thread is still listed and drawn unread on its own row.
            XCTAssertEqual(Set(threads.keys), [unread.id, mentioned.id])
            XCTAssertEqual(threads[unread.id]?.unread, true)
            XCTAssertEqual(threads[unread.id]?.mentions, 0)
            XCTAssertEqual(threads[unread.id]?.accessibilityValue, "unread")
            XCTAssertEqual(threads[mentioned.id]?.unread, true)
            XCTAssertEqual(threads[mentioned.id]?.mentions, 2)
            XCTAssertEqual(threads[mentioned.id]?.accessibilityValue, "unread, 2 mentions")

            // Thread metadata still feeds the projection, the server rail and the Inbox.
            XCTAssertEqual(row.rollup, DiscordStore.ThreadRollup(unreadThreads: 2, mentions: 2, mentionThreads: 1))
        }
        XCTAssertEqual(store.badge(for: guild), DiscordStore.GuildBadge(unread: true, mentions: 2))
        XCTAssertEqual(Set(InboxLists.unreadChannels(store: store).map(\.id)).intersection([prs, unread.id, mentioned.id]),
                       [unread.id, mentioned.id])
    }

    func testUnreadParentKeepsOnlyItsOwnActivityBesideUnreadThreads() throws {
        let busy = thread(1, last: 100)
        let store = try store(threads: [busy],
                              readStates: [ReadState(id: prs, lastMessageID: sf(0), mentionCount: 1),
                                           ReadState(id: busy.id, lastMessageID: sf(50), mentionCount: 2)])
        let row = try XCTUnwrap(entry(store, prs))
        let (parent, threads) = badges(store, row)
        XCTAssertTrue(parent.unread)
        XCTAssertEqual(parent.mentions, 1)
        XCTAssertEqual(parent.accessibilityValue, "unread, 1 mention")
        XCTAssertEqual(threads[busy.id]?.mentions, 2)
        XCTAssertEqual(threads[busy.id]?.accessibilityValue, "unread, 2 mentions")
        XCTAssertEqual(store.badge(for: guild), DiscordStore.GuildBadge(unread: true, mentions: 3),
                       "the rail still sums the parent and its thread once each")
    }

    // MARK: Accessibility

    func testCollapsedCategoryKeepsOwnMentionOnlyChannel() throws {
        let store = try store(threads: [], readStates: [ReadState(id: prs, lastMessageID: sf(1), mentionCount: 3)])
        XCTAssertFalse(store.isUnread(try XCTUnwrap(store.channel(prs))))
        XCTAssertEqual(entry(store, prs, collapsed: [category])?.channel.id, prs)
        XCTAssertEqual(store.badge(for: guild).mentions, 3)
    }

    func testRemovedPrivateMembershipCannotReturnThroughPartialUpdate() throws {
        var row = thread(1, last: 100, joinedAt: 10)
        row.type = .privateThread
        row.ownerID = 6
        let store = try store(threads: [row], readStates: [])
        XCTAssertTrue(store.canSend(in: row))
        dispatch(store, "THREAD_MEMBERS_UPDATE", #"{"id":"\#(row.id)","removed_member_ids":["1"]}"#)
        dispatch(store, "THREAD_UPDATE", #"{"id":"\#(row.id)","type":12,"guild_id":"100","parent_id":"300","owner_id":"6","thread_metadata":{"archived":false}}"#)
        let removed = try XCTUnwrap(store.channel(row.id))
        XCTAssertFalse(store.joinedThreads.contains(row.id))
        XCTAssertNil(removed.member)
        XCTAssertFalse(store.canSend(in: removed))
        dispatch(store, "THREAD_MEMBER_UPDATE", #"{"id":"\#(row.id)","join_timestamp":"\#(stamp(200))"}"#)
        let rejoined = try XCTUnwrap(store.channel(row.id))
        XCTAssertTrue(store.joinedThreads.contains(row.id))
        XCTAssertEqual(rejoined.member?.joinTimestamp, stamp(200))
        XCTAssertFalse(store.isUnread(rejoined), "rejoining after the latest message uses the fresh timestamp")
    }

    func testMembersUpdateRejoinUsesItsAuthoritativeTimestamp() throws {
        let row = thread(1, last: 100, joinedAt: 10)
        let store = try store(threads: [row], readStates: [])
        dispatch(store, "THREAD_MEMBERS_UPDATE", #"{"id":"\#(row.id)","removed_member_ids":["1"]}"#)
        dispatch(store, "THREAD_MEMBERS_UPDATE", #"{"id":"\#(row.id)","added_members":[{"user_id":"1","join_timestamp":"\#(stamp(200))"}]}"#)
        let rejoined = try XCTUnwrap(store.channel(row.id))
        XCTAssertEqual(store.readBoundary(rejoined), sf(200))
        XCTAssertEqual(rejoined.member?.joinTimestamp, stamp(200))
        XCTAssertFalse(store.isUnread(rejoined), "pre-rejoin messages do not become unread")
        XCTAssertFalse(InboxLists.unreadChannels(store: store).contains { $0.id == row.id })
        dispatch(store, "THREAD_MEMBERS_UPDATE", #"{"id":"\#(row.id)","added_members":[{"user_id":"1"}]}"#)
        XCTAssertEqual(store.readBoundary(try XCTUnwrap(store.channel(row.id))), sf(200), "an omitted timestamp cannot erase the known join boundary")
    }

    func testServerThreadSyncPreservesAndMergesJoinTime() throws {
        let row = thread(1, last: 100, joinedAt: 200)
        let store = try store(threads: [row], readStates: [])
        for suffix in ["", #", "members":[]"#, #", "members":[{"id":"\#(row.id)"}]"#,
                       #", "members":[{"id":"\#(row.id)","join_timestamp":"\#(stamp(300))"}]"#] {
            dispatch(store, "THREAD_LIST_SYNC", #"{"guild_id":"100","threads":[{"id":"\#(row.id)","type":11,"parent_id":"300","name":"pr-synced","last_message_id":"\#(sf(100))","thread_metadata":{"archived":false}}]\#(suffix)}"#)
            let synced = try XCTUnwrap(store.channel(row.id))
            let expected = suffix.contains("join_timestamp") ? sf(300) : sf(200)
            XCTAssertEqual(store.readBoundary(synced), expected)
            XCTAssertFalse(store.isUnread(synced))
            XCTAssertFalse(store.badge(for: guild).unread)
            XCTAssertFalse(InboxLists.unreadChannels(store: store).contains { $0.id == row.id })
        }
        // A late sync with no membership payload cannot erase the merged stamp.
        dispatch(store, "THREAD_LIST_SYNC", #"{"guild_id":"100","threads":[{"id":"\#(row.id)","type":11,"parent_id":"300","name":"pr-synced"}]}"#)
        let synced = try XCTUnwrap(store.channel(row.id))
        XCTAssertEqual(store.readBoundary(synced), sf(300))
        XCTAssertEqual(synced.lastMessageID, sf(100))
    }

    func testSpokenValuesSeparateUnreadFromExactMentionTotals() {
        XCTAssertEqual(BadgeAccessibility.rail(unread: true, mentions: 120), "Unread, 120 mentions")
        XCTAssertEqual(BadgeAccessibility.rail(unread: false, mentions: 1), "1 mention")
        XCTAssertEqual(BadgeAccessibility.rail(unread: true, mentions: 0), "Unread")
        XCTAssertEqual(BadgeAccessibility.channel(unread: false, mentions: 2), "2 mentions")
        XCTAssertEqual(BadgeAccessibility.channel(unread: false, mentions: 0), "")
        XCTAssertEqual(BadgeAccessibility.channel(unread: true, mentions: 1), "unread, 1 mention")
        XCTAssertEqual(ThreadOverflowRow.title(hidden: 115, expanded: false), "115 more threads")
        XCTAssertEqual(ThreadOverflowRow.accessibilityLabel(hidden: 1, expanded: false, parent: "prs"), "Show 1 more thread in prs")
    }
}
