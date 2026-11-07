import XCTest
import UIKit
@testable import DuocordNative

final class MarkdownTests: XCTestCase {
    func testInlineStyles() {
        let inlines = DiscordMarkdown.parseInline("**bold** *it* __under__ ~~gone~~ ||secret|| `code`")
        XCTAssertTrue(inlines.contains(.bold([.text("bold")])))
        XCTAssertTrue(inlines.contains(.italic([.text("it")])))
        XCTAssertTrue(inlines.contains(.underline([.text("under")])))
        XCTAssertTrue(inlines.contains(.strike([.text("gone")])))
        XCTAssertTrue(inlines.contains(.spoiler([.text("secret")])))
        XCTAssertTrue(inlines.contains(.code("code")))
    }

    func testMentionsEmojiTimestamps() {
        let inlines = DiscordMarkdown.parseInline("<@123> <@!456> <@&789> <#42> <:wave:99> <a:dance:100> <t:1700000000:R>")
        XCTAssertTrue(inlines.contains(.userMention(123)))
        XCTAssertTrue(inlines.contains(.userMention(456)))
        XCTAssertTrue(inlines.contains(.roleMention(789)))
        XCTAssertTrue(inlines.contains(.channelMention(42)))
        XCTAssertTrue(inlines.contains(.customEmoji(name: "wave", id: 99, animated: false)))
        XCTAssertTrue(inlines.contains(.customEmoji(name: "dance", id: 100, animated: true)))
        XCTAssertTrue(inlines.contains(.timestamp(1_700_000_000, style: "R")))
    }

    func testLinks() {
        let inlines = DiscordMarkdown.parseInline("see [docs](https://example.com/a) and https://apple.com/duo.")
        XCTAssertTrue(inlines.contains(.link(label: [.text("docs")], url: "https://example.com/a")))
        XCTAssertTrue(inlines.contains(.autolink("https://apple.com/duo")))
    }

    func testEscapesAndUnclosed() {
        XCTAssertEqual(DiscordMarkdown.parseInline("\\*not italic\\*"), [.text("*not italic*")])
        XCTAssertEqual(DiscordMarkdown.parseInline("2 * 3 = 6"), [.text("2 * 3 = 6")])
    }

    func testBlocks() {
        let blocks = DiscordMarkdown.parse("# Title\n> quoted\n- item\n```swift\nlet x = 1\n```\n-# small")
        XCTAssertEqual(blocks.first, .heading(level: 1, [.text("Title")]))
        XCTAssertTrue(blocks.contains(.quote([.paragraph([.text("quoted")])])))
        XCTAssertTrue(blocks.contains(.listItem(marker: "•", depth: 0, [.text("item")])))
        XCTAssertTrue(blocks.contains(.codeBlock(language: "swift", code: "let x = 1")))
        XCTAssertTrue(blocks.contains(.subtext([.text("small")])))
    }

    func testFenceMidLine() {
        let blocks = DiscordMarkdown.parse("look: ```\ncode here\n```")
        XCTAssertEqual(blocks.first, .paragraph([.text("look: ")]))
        XCTAssertTrue(blocks.contains(.codeBlock(language: nil, code: "code here")))
    }

    func testJumboEmoji() {
        XCTAssertTrue(MarkdownRenderer.isJumbo(DiscordMarkdown.parse("🎉🎉")))
        XCTAssertTrue(MarkdownRenderer.isJumbo(DiscordMarkdown.parse("<:wave:1>")))
        XCTAssertFalse(MarkdownRenderer.isJumbo(DiscordMarkdown.parse("hi 🎉")))
    }
}

final class ProtoTests: XCTestCase {
    func testGuildFoldersRoundTrip() {
        let guilds: [Snowflake] = (1...8).map { Snowflake(1_000_000_000_000 + UInt64($0)) }
        let proto = MockDiscord.foldersProto(guilds: guilds)
        let parsed = ProtoSettings.guildFolders(base64: proto)
        XCTAssertNotNil(parsed)
        let folder = parsed!.folders.first { $0.name == "Hobbies" }
        XCTAssertEqual(folder?.guildIDs, Array(guilds[2..<5]))
        XCTAssertEqual(folder?.id, 42)
        XCTAssertEqual(folder?.color, 0x5865F2)
        XCTAssertEqual(parsed!.folders.flatMap(\.guildIDs).count, 8)
    }

    func testCDNSize() {
        XCTAssertEqual(cdnSize(102), 128)
        XCTAssertEqual(cdnSize(16), 16)
        XCTAssertEqual(cdnSize(9000), 4096)
    }

    func testSnowflakeDate() {
        // Discord's documented example: 175928847299117063 → 2016-04-30 11:18:25.796 UTC.
        let date = Snowflake(175_928_847_299_117_063).date
        XCTAssertEqual(date.timeIntervalSince1970, 1_462_015_105.796, accuracy: 0.001)
    }
}

@MainActor
final class LayoutTests: XCTestCase {
    func testIndexLookupAndFrames() {
        let layout = MessageListLayout()
        layout.setHeights([10, 20, 30, 40])
        XCTAssertEqual(layout.totalHeight, 100)
        XCTAssertEqual(layout.index(at: 0), 0)
        XCTAssertEqual(layout.index(at: 9.9), 0)
        XCTAssertEqual(layout.index(at: 10), 1)
        XCTAssertEqual(layout.index(at: 59), 2)
        XCTAssertEqual(layout.index(at: 60), 3)
        XCTAssertEqual(layout.index(at: 500), 3)
    }

    func testMeasuredHeightsAreStable() {
        let text = MarkdownRenderer.render("Hello **world**, this wraps across lines on a narrow width. ```\ncode\n```",
                                           context: RenderContext(userName: { _ in nil }, channelName: { _ in nil }, role: { _ in nil },
                                                                  baseFont: Theme.body, textColor: Theme.textPrimary))
        let a = TextMeasurer.size(text, width: 200)
        let b = TextMeasurer.size(text, width: 200)
        XCTAssertEqual(a, b)
        XCTAssertGreaterThan(TextMeasurer.size(text, width: 120).height, a.height)
    }
}

@MainActor
final class TimelineTests: XCTestCase {
    func testPagingKeepsOrderAndWindow() async {
        let mock = MockDiscord()
        let store = DiscordStore()
        let timeline = MessageTimeline(channelID: MockDiscord.imageChannel)
        var changes: [String] = []
        _ = timeline.observe { changes.append("\($0)") }
        await timeline.loadLatest(api: mock, store: store)
        XCTAssertEqual(timeline.messages.count, 50)
        for _ in 0..<14 { await timeline.loadOlder(api: mock, store: store) }
        let ids = timeline.messages.map(\.id)
        XCTAssertEqual(ids, ids.sorted(), "messages stay sorted")
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicates")
        XCTAssertLessThanOrEqual(timeline.messages.count, MessageTimeline.windowLimit)
        XCTAssertTrue(timeline.hasMoreAfter, "trimming the newest end means newer pages must reload")
        XCTAssertTrue(changes.contains { $0.hasPrefix("trimmedBack") })
        await timeline.loadNewer(api: mock, store: store)
        XCTAssertEqual(timeline.messages.map(\.id), timeline.messages.map(\.id).sorted())
    }

    func testPendingEchoIsReplaced() async {
        let timeline = MessageTimeline(channelID: 1)
        let me = User(id: 5, username: "me", globalName: nil, discriminator: nil, avatar: nil, bot: nil)
        var echo = Message(id: Snowflake.at(.now), channelID: 1, guildID: nil, author: me, content: "hi", timestamp: "")
        echo.nonce = "abc"
        timeline.addPending(echo)
        XCTAssertEqual(timeline.sendState(for: echo), .sending)
        var real = Message(id: Snowflake(echo.id.raw + 10), channelID: 1, guildID: nil, author: me, content: "hi", timestamp: "")
        real.nonce = "abc"
        timeline.confirm(nonce: "abc", with: real)
        XCTAssertEqual(timeline.messages.map(\.id), [real.id])
        XCTAssertNil(timeline.sendState(for: real))
    }
}

@MainActor
final class ReviewRegressionTests: XCTestCase {
    private let me = User(id: 5, username: "me", globalName: nil, discriminator: nil, avatar: nil, bot: nil)

    /// Code review 1, finding 2: a gateway message and a pending send that
    /// arrive before the first page must survive the page load.
    func testInitialLoadMergesConcurrentAndPending() async {
        let mock = MockDiscord()
        let store = DiscordStore()
        let timeline = MessageTimeline(channelID: MockDiscord.generalChannel)
        let live = Message(id: Snowflake.at(.now.addingTimeInterval(30)), channelID: MockDiscord.generalChannel, guildID: nil,
                           author: me, content: "live", timestamp: "")
        timeline.receive(live)
        var echo = Message(id: Snowflake.at(.now.addingTimeInterval(60)), channelID: MockDiscord.generalChannel, guildID: nil,
                           author: me, content: "pending", timestamp: "")
        echo.nonce = "n1"
        timeline.addPending(echo)
        await timeline.loadLatest(api: mock, store: store)
        XCTAssertGreaterThan(timeline.messages.count, 2, "history was fetched even though a message arrived first")
        XCTAssertTrue(timeline.messages.contains { $0.id == live.id })
        XCTAssertEqual(timeline.messages.last?.nonce, "n1", "pending echo stays last")
    }

    /// Code review 1, finding 3: confirming a send while the window shows
    /// older history must clear the pending state.
    func testConfirmWhileViewingHistory() async {
        let mock = MockDiscord()
        let store = DiscordStore()
        let timeline = MessageTimeline(channelID: MockDiscord.imageChannel)
        await timeline.loadLatest(api: mock, store: store)
        var echo = Message(id: Snowflake.at(.now), channelID: MockDiscord.imageChannel, guildID: nil, author: me, content: "x", timestamp: "")
        echo.nonce = "n2"
        timeline.addPending(echo)
        await timeline.load(around: timeline.messages[3].id, api: mock, store: store)
        var real = echo
        real.id = Snowflake(echo.id.raw + 1)
        timeline.confirm(nonce: "n2", with: real)
        XCTAssertNil(timeline.sendState(for: echo))
    }
}

@MainActor
final class Review3RegressionTests: XCTestCase {
    private let me = User(id: 5, username: "me", globalName: nil, discriminator: nil, avatar: nil, bot: nil)

    /// Review 3, finding 1: a reaction added while the list is closed must
    /// change the source hash so the cached render is rebuilt.
    func testSourceHashTracksReactions() {
        var message = Message(id: 1, channelID: 1, guildID: nil, author: me, content: "hi", timestamp: "")
        let inputs = MessageBuilder.Inputs(name: "me", color: .white, mentioned: false, replyName: nil, replyColor: nil)
        let before = MessageBuilder.sourceHash(message, inputs: inputs)
        message.reactions = [Reaction(count: 1, me: false, emoji: Emoji(id: nil, name: "👍", animated: false))]
        XCTAssertNotEqual(before, MessageBuilder.sourceHash(message, inputs: inputs))
    }

    /// Review 3, finding 5: spoilers never reach plain text or snippets.
    func testSpoilersRedacted() {
        let context = RenderContext(userName: { _ in nil }, channelName: { _ in nil }, role: { _ in nil },
                                    baseFont: Theme.body, textColor: Theme.textPrimary)
        let plain = MarkdownRenderer.plainText("the end: ||they were twins||", context: context)
        XCTAssertFalse(plain.contains("twins"))
        XCTAssertTrue(plain.contains("spoiler"))
    }

    /// Review 3, finding 2: two overlapping refreshes leave a sorted, duplicate-free window.
    func testOverlappingRefreshes() async {
        let mock = MockDiscord()
        let store = DiscordStore()
        let timeline = MessageTimeline(channelID: MockDiscord.generalChannel)
        await timeline.loadLatest(api: mock, store: store)
        timeline.markNeedsRefresh()
        async let a: Void = timeline.loadLatest(api: mock, store: store)
        timeline.markNeedsRefresh()
        async let b: Void = timeline.loadLatest(api: mock, store: store)
        _ = await (a, b)
        let ids = timeline.messages.map(\.id)
        XCTAssertEqual(ids, ids.sorted())
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

@MainActor
final class RenderCacheTests: XCTestCase {
    /// Round 4: a re-render must drop that message's layouts at every cached width.
    func testInvalidateClearsAllWidths() {
        let cache = ListRenderCache(category: .large)
        let layout = MessageLayout(height: 10, media: [], files: [], embeds: [], reactions: [])
        cache.setLayout(layout, for: 1, width: 382)
        cache.setLayout(layout, for: 1, width: 543)
        cache.invalidate(1)
        XCTAssertNil(cache.layout(1, width: 543))
        XCTAssertNil(cache.layout(1, width: 382), "the other width's layout was stale and must be gone")
    }

    /// Review 6: two lists at different widths interleaving writes never see each other's layouts.
    func testInterleavedWidthsStayIsolated() {
        let cache = ListRenderCache(category: .large)
        let narrow = MessageLayout(height: 100, media: [], files: [], embeds: [], reactions: [])
        let wide = MessageLayout(height: 60, media: [], files: [], embeds: [], reactions: [])
        cache.setLayout(narrow, for: 7, width: 382)
        cache.setLayout(wide, for: 7, width: 543)
        cache.setLayout(narrow, for: 8, width: 382)
        XCTAssertEqual(cache.layout(7, width: 382)?.height, 100)
        XCTAssertEqual(cache.layout(7, width: 543)?.height, 60)
        XCTAssertNil(cache.layout(8, width: 543))
    }

    /// Review 7: four widths in flight keep the first; a fifth evicts the oldest.
    func testFourWidthsRetained() {
        let cache = ListRenderCache(category: .large)
        let layout = MessageLayout(height: 10, media: [], files: [], embeds: [], reactions: [])
        for width in [382.0, 466, 543, 371] { cache.setLayout(layout, for: 1, width: CGFloat(width)) }
        XCTAssertNotNil(cache.layout(1, width: 382))
        cache.setLayout(layout, for: 1, width: 600)
        XCTAssertNil(cache.layout(1, width: 382))
        XCTAssertNotNil(cache.layout(1, width: 600))
    }
}

@MainActor
final class ThemeTests: XCTestCase {
    private var original = Theme.Choice()

    override func setUp() { original = Theme.choice }
    override func tearDown() { ThemeStore.shared.apply(original) }

    private func hex(_ color: UIColor, _ style: UIUserInterfaceStyle) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    /// The appearance and accent survive a relaunch, and switching changes
    /// the existing dynamic colours (no new colour objects needed).
    func testThemePersistsAndSwitches() {
        let suite = "theme-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appearance, .system)
        let before = Theme.revision
        settings.appearance = .onyx
        settings.accent = .green
        XCTAssertNotEqual(Theme.revision, before, "a change bumps the revision caches key on")
        XCTAssertEqual(Theme.choice, Theme.Choice(appearance: .onyx, accent: .green))
        XCTAssertEqual(AppAppearance.onyx.interfaceStyle, .dark)
        XCTAssertEqual(hex(Theme.chatBackground, .dark), 0x000000, "Onyx backgrounds are pure black")
        XCTAssertEqual(hex(Theme.textPrimary, .dark), 0xEDEEF0)
        XCTAssertEqual(hex(Theme.accent, .dark), AccentChoice.green.hex)

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.appearance, .onyx)
        XCTAssertEqual(relaunched.accent, .green)

        relaunched.appearance = .dark
        XCTAssertEqual(hex(Theme.chatBackground, .dark), 0x1A1B1E)
        XCTAssertEqual(AppAppearance.light.interfaceStyle, .light)
        XCTAssertEqual(AppAppearance.system.interfaceStyle, .unspecified)
    }

    /// Rendered text bakes colours: a render cache from before a theme change is stale.
    func testRenderCacheKeysOnTheme() {
        let cache = ListRenderCache(category: .large)
        XCTAssertEqual(cache.theme, Theme.revision)
        ThemeStore.shared.apply(Theme.Choice(appearance: original.appearance == .light ? .dark : .light, accent: original.accent))
        XCTAssertNotEqual(cache.theme, Theme.revision)
    }

    /// Onyx ↔ Dark keeps the dark style: colours set once (a code card's
    /// background) must still re-resolve when only the theme revision changes.
    func testStyleKeepingThemeChangeReResolvesSetOnceColours() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = UIView(frame: window.bounds)
        view.backgroundColor = Theme.codeBackground
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        func layerHex() throws -> UInt32 {
            window.layoutIfNeeded()
            return hex(UIColor(cgColor: try XCTUnwrap(view.layer.backgroundColor)), .dark)
        }
        ThemeStore.shared.apply(Theme.Choice(appearance: .onyx, accent: .blurple))
        ThemeStore.shared.style(window)
        XCTAssertEqual(try layerHex(), 0x0C0C0E)
        ThemeStore.shared.apply(Theme.Choice(appearance: .dark, accent: .blurple))
        ThemeStore.shared.style(window)
        XCTAssertEqual(try layerHex(), 0x111214)
    }

    /// Recents put the newest first, without duplicates.
    func testRecentEmoji() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "recents-test-\(UUID())")!)
        let thumbs = Emoji(id: nil, name: "👍", animated: false)
        let custom = Emoji(id: 1001, name: "hinge", animated: false)
        settings.noteRecent(thumbs)
        settings.noteRecent(custom)
        settings.noteRecent(thumbs)
        XCTAssertEqual(settings.recentEmoji.map(\.reactionKey), ["👍", "hinge:1001"])
    }
}

@MainActor
final class ReactionTests: XCTestCase {
    private let me = User(id: 5, username: "me", globalName: nil, discriminator: nil, avatar: nil, bot: nil)
    private let thumbs = Emoji(id: nil, name: "👍", animated: false)

    private func timeline(reactions: [Reaction] = []) -> MessageTimeline {
        let timeline = MessageTimeline(channelID: 1)
        var message = Message(id: 10, channelID: 1, guildID: nil, author: me, content: "hi", timestamp: "")
        message.reactions = reactions
        timeline.receive(message)
        return timeline
    }

    private func reaction(_ timeline: MessageTimeline) -> Reaction? { timeline.messages.first?.reactions.first }

    private func event(user: Snowflake) -> ReactionEvent {
        ReactionEvent(userID: user, channelID: 1, messageID: 10, emoji: thumbs, burst: false)
    }

    /// Adding and removing show at once; the gateway's echo of your own
    /// change doesn't count it twice; other people's reactions still count.
    func testOptimisticAddAndRemove() async {
        let timeline = timeline()
        var updates = 0
        _ = timeline.observe { if case .updated = $0 { updates += 1 } }
        let add = timeline.sendReaction(thumbs, on: 10, add: true, api: MockDiscord())
        XCTAssertEqual(reaction(timeline)?.count, 1, "shown before the request finishes")
        XCTAssertEqual(reaction(timeline)?.me, true)
        XCTAssertEqual(updates, 1)
        let stuck = await add?.value
        XCTAssertEqual(stuck, .applied)
        timeline.react(event(user: me.id), add: true, me: me.id)
        XCTAssertEqual(reaction(timeline)?.count, 1, "own gateway echo is not counted again")
        timeline.react(event(user: 77), add: true, me: me.id)
        XCTAssertEqual(reaction(timeline)?.count, 2)

        XCTAssertNil(timeline.sendReaction(thumbs, on: 10, add: true, api: MockDiscord()), "already reacted: nothing to do")
        let remove = timeline.sendReaction(thumbs, on: 10, add: false, api: MockDiscord())
        XCTAssertEqual(reaction(timeline)?.count, 1)
        XCTAssertEqual(reaction(timeline)?.me, false)
        _ = await remove?.value
        timeline.react(event(user: me.id), add: false, me: me.id)
        XCTAssertEqual(reaction(timeline)?.count, 1, "own removal echo is not counted again")
    }

    /// A refused request puts the reaction back exactly as it was.
    func testRollbackOnFailure() async {
        let timeline = timeline(reactions: [Reaction(count: 3, me: false, emoji: thumbs)])
        let add = timeline.sendReaction(thumbs, on: 10, add: true, api: OfflineAPI())
        XCTAssertEqual(reaction(timeline)?.count, 4)
        let added = await add?.value
        XCTAssertEqual(added, .failed)
        XCTAssertEqual(reaction(timeline)?.count, 3)
        XCTAssertEqual(reaction(timeline)?.me, false)

        let mine = self.timeline(reactions: [Reaction(count: 1, me: true, emoji: thumbs)])
        let remove = mine.sendReaction(thumbs, on: 10, add: false, api: OfflineAPI())
        XCTAssertNil(reaction(mine), "the only reaction disappears at once")
        _ = await remove?.value
        XCTAssertEqual(reaction(mine)?.count, 1, "and comes back when the removal fails")
        XCTAssertEqual(reaction(mine)?.me, true)

        let heart = Emoji(id: nil, name: "❤️", animated: false)
        let pair = self.timeline(reactions: [Reaction(count: 1, me: true, emoji: thumbs), Reaction(count: 3, me: false, emoji: heart)])
        let removeFirst = pair.sendReaction(thumbs, on: 10, add: false, api: OfflineAPI())
        _ = await removeFirst?.value
        XCTAssertEqual(pair.messages.first?.reactions.map(\.emoji.reactionKey), ["👍", "❤️"], "back in its old place, not moved to the end")
    }

    /// The bug behind "can't react": the emoji was percent-encoded twice.
    func testReactionPathEncodedOnce() {
        let base = URL(string: "https://discord.com/api/v9")!
        let unicode = DiscordREST.url(base: base, path: "channels/1/messages/2/reactions/\(thumbs.reactionPathSegment)/@me")
        XCTAssertEqual(unicode.absoluteString, "https://discord.com/api/v9/channels/1/messages/2/reactions/%F0%9F%91%8D/@me")
        let custom = Emoji(id: 123, name: "blob_wave", animated: false)
        let customURL = DiscordREST.url(base: base, path: "channels/1/messages/2/reactions/\(custom.reactionPathSegment)",
                                        query: [URLQueryItem(name: "limit", value: "100")])
        XCTAssertEqual(customURL.absoluteString, "https://discord.com/api/v9/channels/1/messages/2/reactions/blob_wave%3A123?limit=100")
    }

    /// The mock lists the same reactors every time, you first when you reacted.
    func testMockReactorsDeterministic() async throws {
        let mock = MockDiscord()
        let page = try await mock.messages(channel: MockDiscord.generalChannel, before: nil, after: nil, around: nil, limit: 50)
        let message = try XCTUnwrap(page.first { !$0.reactions.isEmpty })
        let reaction = message.reactions[0]
        let first = try await mock.reactions(channel: MockDiscord.generalChannel, message: message.id, emoji: reaction.emoji, limit: 100)
        let second = try await mock.reactions(channel: MockDiscord.generalChannel, message: message.id, emoji: reaction.emoji, limit: 100)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.count, min(reaction.count, mock.users.count + (reaction.me ? 1 : 0)))
        XCTAssertEqual(first.first?.id == mock.me.id, reaction.me)
    }

    /// Code review 9, finding 3: every reactor is listed, even when the
    /// count is more than half the mock's people.
    func testMockReactorsMatchCount() async throws {
        let mock = MockDiscord()
        let page = try await mock.messages(channel: MockDiscord.generalChannel, before: nil, after: nil, around: nil, limit: 50)
        let reactions = page.flatMap { message in message.reactions.map { (message.id, $0) } }
        XCTAssertTrue(reactions.contains { $0.1.count > mock.users.count / 2 }, "covers the case that used to come up short")
        for (id, reaction) in reactions {
            let users = try await mock.reactions(channel: MockDiscord.generalChannel, message: id, emoji: reaction.emoji, limit: 100)
            XCTAssertEqual(users.count, min(reaction.count, mock.users.count + (reaction.me ? 1 : 0)))
        }
    }

    /// Every picker section shares one grid: cell IDs must not repeat across
    /// sections, or SwiftUI drops the repeats (the server emoji and the first
    /// smileys went missing this way).
    func testPickerCellIDsUniqueAcrossSections() {
        let custom = (0..<6).map { Emoji(id: Snowflake(1_000 + UInt64($0)), name: "e\($0)", animated: false) }
        var cells = EmojiPickerView.cells(section: "recent", emoji: Array(repeating: thumbs, count: 10), names: nil)
        cells += EmojiPickerView.cells(section: "server", emoji: custom, names: nil)
        for group in EmojiCatalog.groups {
            cells += EmojiPickerView.cells(section: group.id, emoji: group.entries.map(\.emoji), names: group.entries.map(\.name))
        }
        XCTAssertEqual(Set(cells.map(\.id)).count, cells.count)
        XCTAssertEqual(cells[10].name, "e0", "custom emoji are named by their name")
        XCTAssertEqual(cells.last?.name, EmojiCatalog.groups.last?.entries.last?.name)
    }

    /// An exact name beats longer names that merely start with the query.
    func testEmojiSearchExactFirst() {
        XCTAssertEqual(EmojiCatalog.search("fire").first?.name, "fire")
        XCTAssertEqual(EmojiCatalog.search("red heart").first?.name, "red heart")
        XCTAssertTrue(EmojiCatalog.search("fire").contains { $0.name == "firefighter" })
        XCTAssertTrue(EmojiCatalog.search("").isEmpty)
    }

    /// A lookup opened as a sheet on the outer display moves to the sidebar
    /// page when the Duo unfolds; profiles and media stay sheets.
    func testLookupSheetMovesToSidebarOnUnfold() {
        let model = AppModel()
        let picker = AppSheet.emojiPicker(channel: 1, message: 2)
        model.fold.isCompact = true
        model.sheet = picker
        model.fold.isCompact = false
        model.sizeClassChanged(compact: false)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.sidebarPanel, picker)

        model.sheet = .user(3)
        model.sizeClassChanged(compact: false)
        XCTAssertEqual(model.sheet, .user(3))
        XCTAssertEqual(model.sidebarPanel, picker)
    }
}

/// Reaction requests that wait for the test to answer each one, so taps,
/// gateway echoes and responses can be ordered exactly.
nonisolated final class ScriptedReactions: DiscordAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var adds: [Bool] = []
    private var answers: [CheckedContinuation<Void, Error>] = []

    private var serverPage: [Message]?
    private var readCount = 0

    /// What each request asked for (true = add), in order.
    var requests: [Bool] { lock.withLock { adds } }
    /// How many times the message was read back (reconciling a lost response).
    var reads: Int { lock.withLock { readCount } }
    /// What a read of the message returns (nil: the read fails).
    var server: [Message]? {
        get { lock.withLock { serverPage } }
        set { lock.withLock { serverPage = newValue } }
    }

    func answer(_ index: Int, failing: Bool = false) {
        answer(index, error: failing ? DiscordError.http(500, "Internal Server Error") : nil)
    }

    func answer(_ index: Int, error: Error?) {
        let continuation = lock.withLock { answers[index] }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func react(channel: Snowflake, message: Snowflake, emoji: Emoji, add: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                adds.append(add)
                answers.append(continuation)
            }
        }
    }

    func messages(channel: Snowflake, before: Snowflake?, after: Snowflake?, around: Snowflake?, limit: Int) async throws -> [Message] {
        let page: [Message]? = lock.withLock {
            readCount += 1
            return serverPage
        }
        guard let page else { throw error }
        return page
    }

    private var error: Error { DiscordError.unauthorized }
    func pins(channel: Snowflake) async throws -> [Message] { throw error }
    func search(guild: Snowflake?, channel: Snowflake?, query: String, offset: Int) async throws -> SearchResult { throw error }
    func mentions(limit: Int, before: Snowflake?) async throws -> [Message] { throw error }
    func forumThreads(channel: Snowflake, offset: Int) async throws -> ThreadSearchResult { throw error }
    func archivedThreads(channel: Snowflake) async throws -> [Channel] { throw error }
    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String) async throws -> Message { throw error }
    func edit(channel: Snowflake, message: Snowflake, content: String) async throws -> Message { throw error }
    func delete(channel: Snowflake, message: Snowflake) async throws { throw error }
    func ack(channel: Snowflake, message: Snowflake) async throws { throw error }
    func typing(channel: Snowflake) async throws { throw error }
    func reactions(channel: Snowflake, message: Snowflake, emoji: Emoji, limit: Int) async throws -> [User] { throw error }
    func patchNotificationSettings(target: NotificationTarget, patch: NotificationPatch) async throws -> GuildSettingsUpdate { throw error }
    func settingsProto() async throws -> String? { throw error }
}

/// Edits and deletes that wait for the test to answer each one.
nonisolated final class ScriptedWrites: DiscordAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var editRequests: [(content: String, answer: CheckedContinuation<Message, Error>)] = []
    private var deleteAnswers: [CheckedContinuation<Void, Error>] = []
    private var readAnswers: [CheckedContinuation<[Message], Error>] = []

    /// The text each edit request sent, in order.
    var edits: [String] { lock.withLock { editRequests.map(\.content) } }
    var deletes: Int { lock.withLock { deleteAnswers.count } }
    var reads: Int { lock.withLock { readAnswers.count } }
    func answerRead(_ index: Int, with page: [Message]) { lock.withLock { readAnswers[index] }.resume(returning: page) }

    func answerEdit(_ index: Int, with message: Message) { lock.withLock { editRequests[index].answer }.resume(returning: message) }
    func failEdit(_ index: Int) { lock.withLock { editRequests[index].answer }.resume(throwing: DiscordError.http(500, "Internal Server Error")) }
    func answerDelete(_ index: Int, failing: Bool) {
        let answer = lock.withLock { deleteAnswers[index] }
        if failing { answer.resume(throwing: DiscordError.http(500, "Internal Server Error")) } else { answer.resume() }
    }

    func edit(channel: Snowflake, message: Snowflake, content: String) async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { editRequests.append((content, continuation)) }
        }
    }

    func delete(channel: Snowflake, message: Snowflake) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { deleteAnswers.append(continuation) }
        }
    }

    private var error: Error { DiscordError.unauthorized }
    func messages(channel: Snowflake, before: Snowflake?, after: Snowflake?, around: Snowflake?, limit: Int) async throws -> [Message] {
        try await withCheckedThrowingContinuation { answer in lock.withLock { readAnswers.append(answer) } }
    }
    func pins(channel: Snowflake) async throws -> [Message] { throw error }
    func search(guild: Snowflake?, channel: Snowflake?, query: String, offset: Int) async throws -> SearchResult { throw error }
    func mentions(limit: Int, before: Snowflake?) async throws -> [Message] { throw error }
    func forumThreads(channel: Snowflake, offset: Int) async throws -> ThreadSearchResult { throw error }
    func archivedThreads(channel: Snowflake) async throws -> [Channel] { throw error }
    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String) async throws -> Message { throw error }
    func ack(channel: Snowflake, message: Snowflake) async throws { throw error }
    func typing(channel: Snowflake) async throws { throw error }
    func react(channel: Snowflake, message: Snowflake, emoji: Emoji, add: Bool) async throws { throw error }
    func reactions(channel: Snowflake, message: Snowflake, emoji: Emoji, limit: Int) async throws -> [User] { throw error }
    func patchNotificationSettings(target: NotificationTarget, patch: NotificationPatch) async throws -> GuildSettingsUpdate { throw error }
    func settingsProto() async throws -> String? { throw error }
}

/// Answers every request from a script: the first `limit` get a 429, the
/// rest succeed. Records each request's method.
nonisolated final class RateLimitedNetwork: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var limitsLeft = 0
    nonisolated(unsafe) private static var seen: [String] = []

    static func reset(limiting count: Int) { lock.withLock { limitsLeft = count; seen = [] } }
    static var methods: [String] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let limited = Self.lock.withLock {
            Self.seen.append(method)
            guard Self.limitsLeft > 0 else { return false }
            Self.limitsLeft -= 1
            return true
        }
        let body = limited ? #"{"message": "You are being rate limited.", "retry_after": 0.01, "global": false}"# : (method == "GET" ? "[]" : "")
        let response = HTTPURLResponse(url: request.url!, statusCode: limited ? 429 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Code review 10, finding 1: a 429 never sends a write again by itself.
final class RateLimitTests: XCTestCase {
    private func rest() -> DiscordREST {
        DiscordREST(credentials: SessionCredentials(token: "test", superProperties: nil, userAgent: "test"),
                    protocolClasses: [RateLimitedNetwork.self])
    }

    /// A read waits out the limit and goes again.
    func testReadsAreRetried() async throws {
        RateLimitedNetwork.reset(limiting: 1)
        let page = try await rest().messages(channel: 1, before: nil, after: nil, around: nil, limit: 50)
        XCTAssertEqual(page.count, 0)
        XCTAssertEqual(RateLimitedNetwork.methods, ["GET", "GET"])
    }

    /// Every write is sent once and fails with the wait, for you to retry.
    func testWritesAreNotRetried() async throws {
        let api = rest()
        let emoji = Emoji(id: nil, name: "👍", animated: false)
        let writes: [(String, () async throws -> Void)] = [
            ("PUT", { try await api.react(channel: 1, message: 2, emoji: emoji, add: true) }),
            ("DELETE", { try await api.react(channel: 1, message: 2, emoji: emoji, add: false) }),
            ("PATCH", { _ = try await api.edit(channel: 1, message: 2, content: "x") }),
            ("DELETE", { try await api.delete(channel: 1, message: 2) }),
            ("POST", { _ = try await api.send(channel: 1, content: "x", replyTo: nil, pingReply: false, attachments: [], nonce: "n") }),
        ]
        for (method, write) in writes {
            RateLimitedNetwork.reset(limiting: 1)
            do {
                try await write()
                XCTFail("\(method) should have failed")
            } catch DiscordError.rateLimited(let wait) {
                XCTAssertEqual(wait, 0.25, accuracy: 0.001, "the wait Discord asked for (at least 0.25 s)")
            } catch {
                XCTFail("\(method): unexpected \(error)")
            }
            XCTAssertEqual(RateLimitedNetwork.methods, [method], "\(method) sent exactly once")
        }
        XCTAssertFalse(DiscordError.mayHaveApplied(DiscordError.rateLimited(retryAfter: 1)), "a 429 did nothing")
    }
}

/// Code review 9, finding 1: your reaction writes against Discord's echoes
/// and responses, in every order they can arrive.
@MainActor
final class ReactionReconcileTests: XCTestCase {
    private let me = User(id: 5, username: "me", globalName: nil, discriminator: nil, avatar: nil, bot: nil)
    private let thumbs = Emoji(id: nil, name: "👍", animated: false)

    private func timeline(reactions: [Reaction] = []) -> MessageTimeline {
        let timeline = MessageTimeline(channelID: 1)
        var message = Message(id: 10, channelID: 1, guildID: nil, author: me, content: "hi", timestamp: "")
        message.reactions = reactions
        timeline.receive(message)
        return timeline
    }

    private func thumbsReaction(_ timeline: MessageTimeline) -> Reaction? {
        timeline.messages.first?.reactions.first { $0.emoji.reactionKey == thumbs.reactionKey }
    }

    private func echo(_ timeline: MessageTimeline, add: Bool, user: Snowflake? = nil) {
        timeline.react(ReactionEvent(userID: user ?? me.id, channelID: 1, messageID: 10, emoji: thumbs, burst: false), add: add, me: me.id)
    }

    /// Waits (briefly) for something a background task sets.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// An echo arriving after the response, or after a newer toggle has
    /// started, changes nothing: the pill keeps showing your latest intent.
    func testDelayedEcho() async {
        let timeline = timeline()
        let api = ScriptedReactions()
        let add = timeline.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 1 }
        api.answer(0)
        let added = await add?.value
        XCTAssertEqual(added, .applied)
        XCTAssertEqual(timeline.reactionConfirmations[10], 1, "the response confirmed it")

        // Remove before the add's echo shows up.
        let remove = timeline.sendReaction(thumbs, on: 10, add: false, api: api)
        XCTAssertNil(thumbsReaction(timeline))
        echo(timeline, add: true)
        XCTAssertNil(thumbsReaction(timeline), "the late add echo doesn't bring the pill back")
        echo(timeline, add: true, user: 77)
        XCTAssertEqual(thumbsReaction(timeline)?.count, 1, "someone else's reaction still counts")
        XCTAssertEqual(thumbsReaction(timeline)?.me, false)
        await eventually { api.requests.count == 2 }
        api.answer(1)
        let removed = await remove?.value
        XCTAssertEqual(removed, .applied)
        echo(timeline, add: false)
        XCTAssertEqual(thumbsReaction(timeline)?.count, 1, "the late remove echo isn't counted again")
        XCTAssertEqual(api.requests, [true, false])
    }

    /// Discord applied the write (its echo arrived), then the response
    /// failed: the reaction stays.
    func testEchoThenFailureKeepsReaction() async {
        let timeline = timeline(reactions: [Reaction(count: 2, me: false, emoji: thumbs)])
        let api = ScriptedReactions()
        let add = timeline.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 1 }
        echo(timeline, add: true)
        XCTAssertEqual(thumbsReaction(timeline)?.count, 3, "own echo not counted twice")
        XCTAssertEqual(timeline.reactionConfirmations[10], 1, "the echo confirmed it")
        api.answer(0, failing: true)
        let outcome = await add?.value
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(thumbsReaction(timeline)?.count, 3, "no rollback")
        XCTAssertEqual(thumbsReaction(timeline)?.me, true)
        XCTAssertEqual(timeline.reactionConfirmations[10], 1, "confirmed once")
        XCTAssertEqual(api.requests, [true], "nothing re-sent")
    }

    /// The same through the mock with `-DuocordMockReactFailAfterEcho`: the
    /// echo reaches the timeline through the gateway, then the response fails.
    func testMockFailAfterEcho() async throws {
        let mock = MockDiscord()
        mock.reactFailsAfterEcho = true
        let channel = MockDiscord.generalChannel
        let timeline = MessageTimeline(channelID: channel)
        await timeline.loadLatest(api: mock, store: DiscordStore())
        let target = try XCTUnwrap(timeline.messages.last { !$0.reactions.contains { $0.emoji.reactionKey == thumbs.reactionKey } })
        let myID = mock.me.id
        mock.echo = { dispatch in
            Task { @MainActor in
                guard let event = try? dispatch.decode(ReactionEvent.self) else { return }
                timeline.react(event, add: dispatch.name == "MESSAGE_REACTION_ADD", me: myID)
            }
        }
        let outcome = await timeline.sendReaction(thumbs, on: target.id, add: true, api: mock)?.value
        XCTAssertEqual(outcome, .applied)
        let shown = timeline.messages.first { $0.id == target.id }?.reactions.first { $0.emoji.reactionKey == thumbs.reactionKey }
        XCTAssertEqual(shown?.me, true, "kept, as Discord has it")
        XCTAssertEqual(shown?.count, 1)
        let server = try await mock.messages(channel: channel, before: nil, after: nil, around: target.id, limit: 3)
        XCTAssertEqual(server.first { $0.id == target.id }?.reactions.first { $0.emoji.reactionKey == thumbs.reactionKey }?.me, true)
    }

    /// Taps while a write is in flight queue behind it and coalesce: the
    /// last tap wins, and nothing you didn't ask for is sent.
    func testOverlappingTapsFinalIntentWins() async {
        let timeline = timeline()
        let api = ScriptedReactions()
        let first = timeline.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 1 }
        let second = timeline.sendReaction(thumbs, on: 10, add: false, api: api)
        let third = timeline.sendReaction(thumbs, on: 10, add: true, api: api)
        XCTAssertEqual(thumbsReaction(timeline)?.me, true)
        XCTAssertEqual(thumbsReaction(timeline)?.count, 1)
        XCTAssertEqual(api.requests.count, 1, "one write at a time")
        api.answer(0)
        let outcomes = [await first?.value, await second?.value, await third?.value]
        XCTAssertEqual(outcomes, [.superseded, .superseded, .applied])
        XCTAssertEqual(api.requests, [true], "add, remove, add while sending: the add already says it all")

        // Double tap: add is sent, then the remove the second tap asked for.
        let other = self.timeline()
        let add = other.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 2 }
        let remove = other.sendReaction(thumbs, on: 10, add: false, api: api)
        api.answer(1)
        await eventually { api.requests.count == 3 }
        XCTAssertEqual(api.requests.last, false)
        api.answer(2)
        let pair = [await add?.value, await remove?.value]
        XCTAssertEqual(pair, [.superseded, .applied])
        XCTAssertNil(thumbsReaction(other))
    }

    /// An older write failing doesn't undo a newer tap; a refused write
    /// that is still your latest tap does go back.
    func testOlderFailureVersusNewerIntent() async {
        let timeline = timeline()
        let api = ScriptedReactions()
        let add = timeline.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 1 }
        let remove = timeline.sendReaction(thumbs, on: 10, add: false, api: api)
        api.answer(0, failing: true)
        let outcomes = [await add?.value, await remove?.value]
        XCTAssertEqual(outcomes, [.superseded, .applied], "Discord has no reaction, as the newer tap asked")
        XCTAssertNil(thumbsReaction(timeline))
        XCTAssertEqual(api.requests, [true])

        // Add, remove, add: the failed add is sent again for the newer add
        // tap; when that fails too, the pill goes back.
        let again = self.timeline()
        let first = again.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 2 }
        _ = again.sendReaction(thumbs, on: 10, add: false, api: api)
        let last = again.sendReaction(thumbs, on: 10, add: true, api: api)
        api.answer(1, failing: true)
        await eventually { api.requests.count == 3 }
        XCTAssertEqual(thumbsReaction(again)?.me, true, "no rollback while a newer tap is pending")
        api.answer(2, failing: true)
        let results = [await first?.value, await last?.value]
        XCTAssertEqual(results, [.superseded, .failed])
        XCTAssertNil(thumbsReaction(again), "rolled back to what Discord has")
        XCTAssertEqual(api.requests, [true, true, true])
    }

    /// The message as a read of Discord returns it, with or without your 👍.
    private func serverCopy(mine: Bool) -> [Message] {
        var message = Message(id: 10, channelID: 1, guildID: nil, author: me, content: "hi", timestamp: "")
        if mine { message.reactions = [Reaction(count: 1, me: true, emoji: thumbs)] }
        return [message]
    }

    /// Code review 10, finding 2 (the reviewer's sequence): add and remove
    /// succeed, a third add is in flight when the first two's echoes arrive
    /// late, then it fails. The echoes belong to the earlier writes, so they
    /// don't confirm the third; a read shows Discord has no reaction.
    func testLateEchoesDontConfirmRefusedAdd() async {
        let timeline = timeline()
        let api = ScriptedReactions()
        let first = timeline.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 1 }
        api.answer(0)
        _ = await first?.value
        let second = timeline.sendReaction(thumbs, on: 10, add: false, api: api)
        await eventually { api.requests.count == 2 }
        api.answer(1)
        _ = await second?.value
        let third = timeline.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 3 }
        echo(timeline, add: true)
        echo(timeline, add: false)
        XCTAssertEqual(thumbsReaction(timeline)?.me, true, "still showing the third tap")
        XCTAssertEqual(thumbsReaction(timeline)?.count, 1, "old echoes aren't counted")
        api.server = serverCopy(mine: false)
        api.answer(2, failing: true)
        let outcome = await third?.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(thumbsReaction(timeline), "the pill shows what Discord has")
        XCTAssertEqual(api.reads, 1, "a lost response is checked with one read")
        XCTAssertEqual(api.requests, [true, false, true], "and nothing is re-sent")
    }

    /// The same, with a refusal (4xx): Discord did nothing, so there's
    /// nothing to read back.
    func testLateEchoesThenRefusalNeedsNoRead() async {
        let timeline = timeline()
        let api = ScriptedReactions()
        for (index, add) in [true, false].enumerated() {
            let request = timeline.sendReaction(thumbs, on: 10, add: add, api: api)
            await eventually { api.requests.count == index + 1 }
            api.answer(index)
            _ = await request?.value
        }
        let third = timeline.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 3 }
        echo(timeline, add: true)
        echo(timeline, add: false)
        api.answer(2, error: DiscordError.rateLimited(retryAfter: 2))
        let outcome = await third?.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(thumbsReaction(timeline))
        XCTAssertEqual(api.reads, 0)
        XCTAssertEqual(api.requests, [true, false, true])
    }

    /// A lost response for a write Discord did apply (no echo yet): the read
    /// says so, the reaction stays, and its echo arriving later isn't counted.
    func testLostResponseReadShowsApplied() async {
        let timeline = timeline(reactions: [Reaction(count: 2, me: false, emoji: thumbs)])
        let api = ScriptedReactions()
        let add = timeline.sendReaction(thumbs, on: 10, add: true, api: api)
        await eventually { api.requests.count == 1 }
        api.server = serverCopy(mine: true)
        api.answer(0, error: URLError(.timedOut))
        let outcome = await add?.value
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(thumbsReaction(timeline)?.me, true)
        XCTAssertEqual(thumbsReaction(timeline)?.count, 3)
        XCTAssertEqual(timeline.reactionConfirmations[10], 1)
        echo(timeline, add: true)
        XCTAssertEqual(thumbsReaction(timeline)?.count, 3, "its late echo isn't counted again")
        XCTAssertEqual(api.requests, [true])
    }

    /// Echoes of finished writes arriving after all of them still change
    /// nothing (they used to re-add the pill once no write was queued).
    func testLateEchoesAfterWritesFinish() async {
        let timeline = timeline(reactions: [Reaction(count: 1, me: false, emoji: thumbs)])
        let api = ScriptedReactions()
        for (index, add) in [true, false].enumerated() {
            let request = timeline.sendReaction(thumbs, on: 10, add: add, api: api)
            await eventually { api.requests.count == index + 1 }
            api.answer(index)
            _ = await request?.value
        }
        echo(timeline, add: true)
        echo(timeline, add: false)
        XCTAssertEqual(thumbsReaction(timeline)?.me, false)
        XCTAssertEqual(thumbsReaction(timeline)?.count, 1)
        // Your reaction from another device still shows.
        echo(timeline, add: true)
        XCTAssertEqual(thumbsReaction(timeline)?.me, true)
        XCTAssertEqual(thumbsReaction(timeline)?.count, 2)
    }
}

@MainActor
final class OwnMessageTests: XCTestCase {
    private let me = User(id: 900_000_000_000_000_001, username: "you", globalName: "You", discriminator: "0", avatar: nil, bot: false)

    private func timeline(_ contents: [String] = ["one", "two", "three"]) -> MessageTimeline {
        let timeline = MessageTimeline(channelID: 1)
        for (index, content) in contents.enumerated() {
            timeline.receive(Message(id: Snowflake(UInt64(10 + index)), channelID: 1, guildID: nil, author: me, content: content, timestamp: ""))
        }
        return timeline
    }

    /// Waits (briefly) for something a background task sets.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// An edit shows at once, marked edited; a refused one puts the old text back.
    func testEditOptimisticAndRollback() async {
        let timeline = timeline()
        var updated: [Set<Snowflake>] = []
        _ = timeline.observe { if case .updated(let ids) = $0 { updated.append(ids) } }
        let request = timeline.sendEdit(11, content: "two!", api: OfflineAPI())
        XCTAssertEqual(timeline.messages[1].content, "two!", "shown before the request finishes")
        XCTAssertTrue(timeline.messages[1].isEdited)
        XCTAssertEqual(updated, [[11]], "only that row re-renders (its height is re-measured)")
        let stuck = await request?.value
        XCTAssertEqual(stuck, false)
        XCTAssertEqual(timeline.messages[1].content, "two")
        XCTAssertFalse(timeline.messages[1].isEdited, "the edited mark goes too")
        XCTAssertNil(timeline.sendEdit(11, content: "two", api: OfflineAPI()), "unchanged text: nothing to send")
    }

    /// A successful edit (mock) keeps the new text, and the gateway echo
    /// arriving as well changes nothing visible.
    func testEditSucceedsWithEcho() async throws {
        let mock = MockDiscord()
        let channel = MockDiscord.generalChannel
        let page = try await mock.messages(channel: channel, before: nil, after: nil, around: nil, limit: 50)
        let own = try XCTUnwrap(page.first { $0.author.id == mock.me.id }, "mock history has your own messages")
        let timeline = MessageTimeline(channelID: channel)
        await timeline.loadLatest(api: mock, store: DiscordStore())
        var echoes: [GatewayDispatch] = []
        let lock = NSLock()
        mock.echo = { dispatch in lock.withLock { echoes.append(dispatch) } }
        let request = timeline.sendEdit(own.id, content: "edited text", api: mock)
        let stuck = await request?.value
        XCTAssertEqual(stuck, true)
        let update = try XCTUnwrap(lock.withLock { echoes.first })
        XCTAssertEqual(update.name, "MESSAGE_UPDATE")
        timeline.update(try update.decode(MessageUpdate.self))
        let message = try XCTUnwrap(timeline.messages.first { $0.id == own.id })
        XCTAssertEqual(message.content, "edited text")
        XCTAssertTrue(message.isEdited)
        // Someone else's message can't be edited.
        let other = try XCTUnwrap(page.first { $0.author.id != mock.me.id })
        let refused = await timeline.sendEdit(other.id, content: "nope", api: mock)?.value
        XCTAssertEqual(refused, false)
        XCTAssertEqual(timeline.messages.first { $0.id == other.id }?.content, other.content)
    }

    /// A delete removes the row at once; a refused one puts it back in place.
    func testDeleteOptimisticAndRollback() async {
        let timeline = timeline()
        let request = timeline.sendDelete(11, api: OfflineAPI())
        XCTAssertEqual(timeline.messages.map(\.content), ["one", "three"])
        let deleted = await request?.value
        XCTAssertEqual(deleted, false)
        XCTAssertEqual(timeline.messages.map(\.content), ["one", "two", "three"], "back between its neighbours")
        XCTAssertNil(timeline.sendDelete(99, api: OfflineAPI()), "not in the window: nothing to do")
    }

    /// Mock writes emit Discord's gateway events before the HTTP response,
    /// and applying both leaves exactly one copy of each change.
    func testMockEchoOrdering() async throws {
        let mock = MockDiscord()
        let channel = MockDiscord.generalChannel
        let timeline = MessageTimeline(channelID: channel)
        await timeline.loadLatest(api: mock, store: DiscordStore())
        var events: [String] = []
        var dispatches: [GatewayDispatch] = []
        let lock = NSLock()
        mock.echo = { dispatch in lock.withLock { dispatches.append(dispatch) } }

        // Send: the echo replaces the local copy; the later response is a no-op.
        var echo = Message(id: Snowflake.at(.now), channelID: channel, guildID: nil, author: mock.me, content: "hello", timestamp: "")
        echo.nonce = "nonce-1"
        timeline.addPending(echo)
        let sent = try await mock.send(channel: channel, content: "hello", replyTo: nil, pingReply: true, attachments: [], nonce: "nonce-1")
        let created = try XCTUnwrap(lock.withLock { dispatches.last })
        events.append(created.name)
        let gatewayCopy = try created.decode(Message.self)
        XCTAssertEqual(gatewayCopy.nonce, "nonce-1")
        timeline.receive(gatewayCopy)
        timeline.confirm(nonce: "nonce-1", with: sent)
        XCTAssertEqual(timeline.messages.filter { $0.content == "hello" }.count, 1, "no duplicate from echo + response")
        XCTAssertNil(timeline.sendState(for: sent))

        // Edit, then delete, the sent message.
        let edit = timeline.sendEdit(sent.id, content: "hello again", api: mock)
        _ = await edit?.value
        events.append(try XCTUnwrap(lock.withLock { dispatches.last }).name)
        let delete = timeline.sendDelete(sent.id, api: mock)
        _ = await delete?.value
        let deleted = try XCTUnwrap(lock.withLock { dispatches.last })
        events.append(deleted.name)
        timeline.remove([try deleted.decode(MessageDelete.self).id])
        XCTAssertFalse(timeline.messages.contains { $0.id == sent.id })

        // React and unreact: your own echo isn't counted twice.
        let target = try XCTUnwrap(timeline.messages.last)
        let thumbs = Emoji(id: nil, name: "👍", animated: false)
        let before = target.reactions.first { $0.emoji.reactionKey == "👍" }?.count ?? 0
        for add in [true, false] {
            let request = timeline.sendReaction(thumbs, on: target.id, add: add, api: mock)
            _ = await request?.value
            let event = try XCTUnwrap(lock.withLock { dispatches.last })
            events.append(event.name)
            timeline.react(try event.decode(ReactionEvent.self), add: add, me: mock.me.id)
            let count = timeline.messages.last?.reactions.first { $0.emoji.reactionKey == "👍" }?.count ?? 0
            XCTAssertEqual(count, before + (add ? 1 : 0))
        }
        XCTAssertEqual(events, ["MESSAGE_CREATE", "MESSAGE_UPDATE", "MESSAGE_DELETE", "MESSAGE_REACTION_ADD", "MESSAGE_REACTION_REMOVE"])
    }

    /// Replies carry allowed_mentions with replied_user set by the "@" toggle;
    /// plain messages carry none.
    func testAllowedMentionsEncoding() async throws {
        func json(_ body: [String: JSONValue]) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        }
        let off = try json(DiscordREST.sendBody(channel: 1, content: "hi", replyTo: 2, pingReply: false, nonce: "n"))
        let mentions = try XCTUnwrap(off["allowed_mentions"] as? [String: Any])
        XCTAssertEqual(mentions["replied_user"] as? Bool, false)
        XCTAssertEqual(mentions["parse"] as? [String], ["users", "roles", "everyone"])
        XCTAssertEqual((off["message_reference"] as? [String: Any])?["message_id"] as? String, "2")
        let on = try json(DiscordREST.sendBody(channel: 1, content: "hi", replyTo: 2, pingReply: true, nonce: "n"))
        XCTAssertEqual((on["allowed_mentions"] as? [String: Any])?["replied_user"] as? Bool, true)
        let plain = try json(DiscordREST.sendBody(channel: 1, content: "hi", replyTo: nil, pingReply: false, nonce: "n"))
        XCTAssertNil(plain["allowed_mentions"])
        XCTAssertNil(plain["message_reference"])

        // The app passes the toggle through to the request (mock records it).
        let mock = MockDiscord()
        let page = try await mock.messages(channel: MockDiscord.generalChannel, before: nil, after: nil, around: nil, limit: 5)
        let reply = try await mock.send(channel: MockDiscord.generalChannel, content: "re", replyTo: page[0].id, pingReply: false, attachments: [], nonce: "n2")
        XCTAssertEqual(mock.sent.last?.pingReply, false)
        XCTAssertTrue(reply.mentions.isEmpty, "no ping when the toggle is off")
    }

    /// Edit mode sets the draft aside and puts it back on Cancel; a refused
    /// save restores the old text and shows an error.
    func testEditModeRestoresDraftAndReportsFailure() async {
        let model = AppModel()
        model.store.apply(ready: MockDiscord().readyPayload())
        model.store.upsert(channel: Channel(id: 1, type: .dm))
        let mine = Message(id: 20, channelID: 1, guildID: nil, author: me, content: "original", timestamp: "")
        model.timeline(for: 1).receive(mine)
        model.drafts[1] = Draft(text: "half-written")
        model.beginEdit(mine)
        XCTAssertEqual(model.drafts[1]?.text, "original")
        XCTAssertEqual(model.drafts[1]?.editing?.id, 20)
        model.cancelEdit(in: 1)
        XCTAssertEqual(model.drafts[1], Draft(text: "half-written"), "Cancel restores the draft")

        model.beginEdit(mine)
        model.drafts[1]?.text = "changed"
        model.send(in: 1) // Save (OfflineAPI refuses it)
        XCTAssertEqual(model.drafts[1], Draft(text: "half-written"), "Save leaves edit mode at once")
        XCTAssertEqual(model.timeline(for: 1).messages.first?.content, "changed")
        await eventually { model.toast != nil }
        XCTAssertEqual(model.toast?.text, "Your Discord session ended. Sign in again.")
        XCTAssertEqual(model.timeline(for: 1).messages.first?.content, "original")
    }

    /// A reaction Discord refused doesn't join Recently Used, and says so.
    func testFailedReactionNotRecent() async {
        let model = AppModel()
        model.store.apply(ready: MockDiscord().readyPayload())
        model.store.upsert(channel: Channel(id: 2, type: .dm))
        let message = Message(id: 30, channelID: 2, guildID: nil, author: me, content: "x", timestamp: "")
        model.timeline(for: 2).receive(message)
        let rare = Emoji(id: nil, name: "🦑", animated: false)
        let before = model.settings.recentEmoji
        model.react(rare, add: true, message: 30, channel: 2)
        await eventually { model.toast != nil }
        XCTAssertEqual(model.toast?.text, "Your Discord session ended. Sign in again.")
        XCTAssertEqual(model.settings.recentEmoji, before)
        XCTAssertNil(model.timeline(for: 2).messages.first?.reactions.first, "and the pill went back")
    }

    private func saved(_ content: String, id: Snowflake = 11) -> Message {
        var message = Message(id: id, channelID: 1, guildID: nil, author: me, content: content, timestamp: "")
        message.editedTimestamp = "2026-11-01T00:00:00Z"
        return message
    }

    /// Code review 10, finding 3: saves of one message go one at a time, an
    /// older save's response never replaces newer text, and a save made moot
    /// before it went out isn't sent.
    func testEditsSerializedNewestWins() async {
        let timeline = timeline()
        let api = ScriptedWrites()
        let first = timeline.sendEdit(11, content: "first", api: api)
        await eventually { api.edits.count == 1 }
        let second = timeline.sendEdit(11, content: "second", api: api)
        let third = timeline.sendEdit(11, content: "third", api: api)
        XCTAssertEqual(timeline.messages[1].content, "third")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(api.edits, ["first"], "one at a time")
        api.answerEdit(0, with: saved("first"))
        let firstSaved = await first?.value
        XCTAssertEqual(firstSaved, true)
        XCTAssertEqual(timeline.messages[1].content, "third", "the older response doesn't replace newer text")
        await eventually { api.edits.count == 2 }
        XCTAssertEqual(api.edits, ["first", "third"], "the moot second save is skipped")
        let secondSaved = await second?.value
        XCTAssertEqual(secondSaved, true, "replaced, not failed")
        // The newest save fails: back to what Discord has (the first save).
        api.failEdit(1)
        let thirdSaved = await third?.value
        XCTAssertEqual(thirdSaved, false)
        XCTAssertEqual(timeline.messages[1].content, "first")
        XCTAssertTrue(timeline.messages[1].isEdited)

        // An older save failing doesn't roll back a newer one that succeeds.
        let again = self.timeline()
        let older = again.sendEdit(11, content: "older", api: api)
        await eventually { api.edits.count == 3 }
        let newer = again.sendEdit(11, content: "newer", api: api)
        api.failEdit(2)
        let olderSaved = await older?.value
        XCTAssertEqual(olderSaved, true, "replaced: the newer save decides, so no error yet")
        XCTAssertEqual(again.messages[1].content, "newer", "no rollback while a newer save is queued")
        await eventually { api.edits.count == 4 }
        api.answerEdit(3, with: saved("newer"))
        let newerSaved = await newer?.value
        XCTAssertEqual(newerSaved, true)
        XCTAssertEqual(again.messages[1].content, "newer")
    }

    /// Code review 10, finding 4 (edit): Discord's MESSAGE_UPDATE for your
    /// save arrived, then its response failed: the saved text stays.
    func testEditEchoThenFailureKeepsText() async {
        let timeline = timeline()
        let api = ScriptedWrites()
        let request = timeline.sendEdit(11, content: "saved", api: api)
        await eventually { api.edits.count == 1 }
        timeline.update(MessageUpdate(id: 11, channelID: 1, content: "saved", editedTimestamp: "2026-11-01T00:00:00Z", embeds: nil))
        api.failEdit(0)
        let outcome = await request?.value
        XCTAssertEqual(outcome, true, "Discord saved it: no error")
        XCTAssertEqual(timeline.messages[1].content, "saved")
        XCTAssertEqual(timeline.messages[1].editedTimestamp, "2026-11-01T00:00:00Z")
    }

    /// Code review 10, finding 4 (delete): Discord's MESSAGE_DELETE arrived
    /// (the row was already gone), then the response failed: it stays deleted.
    func testDeleteEchoThenFailureStaysDeleted() async {
        let timeline = timeline()
        let api = ScriptedWrites()
        let request = timeline.sendDelete(11, api: api)
        await eventually { api.deletes == 1 }
        timeline.remove([11])
        api.answerDelete(0, failing: true)
        let outcome = await request?.value
        XCTAssertEqual(outcome, true, "Discord deleted it: no error")
        XCTAssertEqual(timeline.messages.map(\.content), ["one", "three"])

        // Without the event, a failure still puts it back.
        let other = self.timeline()
        let refused = other.sendDelete(11, api: api)
        await eventually { api.deletes == 2 }
        api.answerDelete(1, failing: true)
        let refusedOutcome = await refused?.value
        XCTAssertEqual(refusedOutcome, false)
        XCTAssertEqual(other.messages.map(\.content), ["one", "two", "three"])
    }

    func testOlderHTTPResponseKeepsNewerGatewayEdit() async {
        let timeline = timeline()
        let api = ScriptedWrites()
        let request = timeline.sendEdit(11, content: "local-A", api: api)
        await eventually { api.edits.count == 1 }
        timeline.update(MessageUpdate(id: 11, channelID: 1, content: "local-A", editedTimestamp: "2026-11-01T00:00:01Z", embeds: nil))
        timeline.update(MessageUpdate(id: 11, channelID: 1, content: "remote-B", editedTimestamp: "2026-11-01T00:00:02Z", embeds: nil))
        var response = saved("local-A")
        response.editedTimestamp = "2026-11-01T00:00:01Z"
        api.answerEdit(0, with: response)
        let outcome = await request?.value
        XCTAssertEqual(outcome, true)
        XCTAssertEqual(timeline.messages[1].content, "remote-B")
        XCTAssertEqual(timeline.messages[1].editedTimestamp, "2026-11-01T00:00:02Z")
    }

    func testStaleRefreshCannotResurrectConfirmedDelete() async {
        let timeline = timeline()
        let page = timeline.messages
        let api = ScriptedWrites()
        let refresh = Task { await timeline.loadLatest(api: api, store: DiscordStore()) }
        await eventually { api.reads == 1 }
        let deletion = timeline.sendDelete(11, api: api)
        await eventually { api.deletes == 1 }
        timeline.remove([11])
        api.answerDelete(0, failing: false)
        let deleted = await deletion?.value
        XCTAssertEqual(deleted, true)
        XCTAssertNil(timeline.index(of: 11))
        api.answerRead(0, with: page)
        await refresh.value
        XCTAssertNil(timeline.index(of: 11), "the older GET page must respect the gateway deletion")
    }

    func testAroundPageContinuationUsesUnfilteredPage() async {
        for (target, deleted): (Snowflake, Snowflake) in [(100, 76), (101, 125)] {
            let timeline = MessageTimeline(channelID: 1)
            let api = ScriptedWrites()
            let request = Task { await timeline.load(around: target, api: api, store: DiscordStore()) }
            await eventually { api.reads == 1 }
            timeline.remove([deleted])
            let page = (76...125).map { id in
                Message(id: Snowflake(UInt64(id)), channelID: 1, guildID: nil, author: me, content: "row", timestamp: "")
            }
            api.answerRead(0, with: page)
            await request.value
            XCTAssertNil(timeline.index(of: deleted))
            XCTAssertEqual(timeline.messages.count, 49)
            XCTAssertTrue(timeline.hasMoreBefore)
            XCTAssertTrue(timeline.hasMoreAfter)
        }
    }

    func testSameRevisionHTTPCompletesMissingGatewayEmbeds() async throws {
        let timeline = timeline()
        let api = ScriptedWrites()
        let request = timeline.sendEdit(11, content: "with link", api: api)
        await eventually { api.edits.count == 1 }
        let stamp = "2026-11-01T00:00:01.123456Z"
        timeline.update(MessageUpdate(id: 11, channelID: 1, content: "with link", editedTimestamp: stamp, embeds: nil))
        var response = saved("with link")
        response.editedTimestamp = stamp
        response.embeds = [try JSONDecoder().decode(Embed.self, from: Data(#"{"type":"rich","title":"new preview"}"#.utf8))]
        api.answerEdit(0, with: response)
        _ = await request?.value
        XCTAssertEqual(timeline.messages[1].embeds, response.embeds)
    }

    func testSameRevisionGatewayEmbedsArePreserved() async throws {
        for contentInEmbedUpdate in [true, false] {
            let timeline = timeline()
            let api = ScriptedWrites()
            let request = timeline.sendEdit(11, content: "with link", api: api)
            await eventually { api.edits.count == 1 }
            let stamp = "2026-11-01T00:00:01.123456Z"
            let preview = try JSONDecoder().decode(Embed.self, from: Data(#"{"type":"rich","title":"gateway preview"}"#.utf8))
            timeline.update(MessageUpdate(id: 11, channelID: 1, content: "with link", editedTimestamp: stamp, embeds: nil))
            timeline.update(MessageUpdate(id: 11, channelID: 1, content: contentInEmbedUpdate ? "with link" : nil,
                                          editedTimestamp: stamp, embeds: [preview]))
            var response = saved("with link")
            response.editedTimestamp = stamp
            api.answerEdit(0, with: response)
            _ = await request?.value
            XCTAssertEqual(timeline.messages[1].embeds, [preview])
        }
    }

    func testUnstampedGatewayEmbedsSurviveEditConfirmation() async throws {
        for echoHasTimestamp in [true, false] {
            for echoFirst in [false, true] {
                let timeline = timeline()
                let api = ScriptedWrites()
                let request = timeline.sendEdit(11, content: "with link", api: api)
                await eventually { api.edits.count == 1 }
                let stamp = "2026-11-01T00:00:01.123456Z"
                let preview = try JSONDecoder().decode(Embed.self, from: Data(#"{"type":"rich","title":"generated preview"}"#.utf8))
                if echoFirst {
                    timeline.update(MessageUpdate(id: 11, channelID: 1, content: "with link", editedTimestamp: echoHasTimestamp ? stamp : nil, embeds: nil))
                }
                timeline.update(MessageUpdate(id: 11, channelID: 1, content: nil, editedTimestamp: nil, embeds: [preview]))
                if !echoFirst {
                    timeline.update(MessageUpdate(id: 11, channelID: 1, content: "with link", editedTimestamp: echoHasTimestamp ? stamp : nil, embeds: nil))
                }
                XCTAssertEqual(timeline.messages[1].embeds, [preview])
                var response = saved("with link")
                response.editedTimestamp = stamp
                api.answerEdit(0, with: response)
                _ = await request?.value
                XCTAssertEqual(timeline.messages[1].embeds, [preview], "an older HTTP snapshot cannot erase a received preview")
            }
        }
    }

    func testQueuedEditDoesNotInheritUnstampedPreviewFromEarlierSave() async throws {
        let timeline = timeline()
        let api = ScriptedWrites()
        let first = timeline.sendEdit(11, content: "first link", api: api)
        await eventually { api.edits.count == 1 }
        let preview = try JSONDecoder().decode(Embed.self, from: Data(#"{"type":"rich","title":"first preview"}"#.utf8))
        timeline.update(MessageUpdate(id: 11, channelID: 1, content: nil, editedTimestamp: nil, embeds: [preview]))
        let second = timeline.sendEdit(11, content: "no link", api: api)
        var response = saved("first link")
        response.editedTimestamp = "2026-11-01T00:00:01Z"
        api.answerEdit(0, with: response)
        _ = await first?.value
        await eventually { api.edits.count == 2 }
        response.content = "no link"
        response.editedTimestamp = "2026-11-01T00:00:02Z"
        api.answerEdit(1, with: response)
        _ = await second?.value
        XCTAssertEqual(timeline.messages[1].content, "no link")
        XCTAssertTrue(timeline.messages[1].embeds.isEmpty, "preview authority ends at the edit that received it")
    }

    func testUnstampedPreviewWithoutContentEchoSurvivesHTTP() async throws {
        let timeline = timeline()
        let api = ScriptedWrites()
        let request = timeline.sendEdit(11, content: "with link", api: api)
        await eventually { api.edits.count == 1 }
        let preview = try JSONDecoder().decode(Embed.self, from: Data(#"{"type":"rich","title":"generated preview"}"#.utf8))
        timeline.update(MessageUpdate(id: 11, channelID: 1, content: nil, editedTimestamp: nil, embeds: [preview]))
        api.answerEdit(0, with: saved("with link"))
        _ = await request?.value
        XCTAssertEqual(timeline.messages[1].content, "with link")
        XCTAssertEqual(timeline.messages[1].embeds, [preview])
    }

    func testQueuedEditFailureRestoresUnstampedGatewayPreview() async throws {
        let timeline = timeline()
        let api = ScriptedWrites()
        let first = timeline.sendEdit(11, content: "first link", api: api)
        await eventually { api.edits.count == 1 }
        let preview = try JSONDecoder().decode(Embed.self, from: Data(#"{"type":"rich","title":"first preview"}"#.utf8))
        timeline.update(MessageUpdate(id: 11, channelID: 1, content: nil, editedTimestamp: nil, embeds: [preview]))
        let second = timeline.sendEdit(11, content: "refused link", api: api)
        api.answerEdit(0, with: saved("first link"))
        _ = await first?.value
        await eventually { api.edits.count == 2 }
        api.failEdit(1)
        let applied = await second?.value
        XCTAssertEqual(applied, false)
        XCTAssertEqual(timeline.messages[1].content, "first link")
        XCTAssertEqual(timeline.messages[1].embeds, [preview])
    }

    func testQueuedEditsPreserveSubMillisecondOrdering() async {
        let timeline = timeline()
        let api = ScriptedWrites()
        let first = timeline.sendEdit(11, content: "local-A", api: api)
        await eventually { api.edits.count == 1 }
        timeline.update(MessageUpdate(id: 11, channelID: 1, content: "local-A", editedTimestamp: "2026-11-01T00:00:01.123456Z", embeds: nil))
        let second = timeline.sendEdit(11, content: "local-B", api: api)
        var response = saved("local-A")
        response.editedTimestamp = "2026-11-01T00:00:01.123456Z"
        api.answerEdit(0, with: response)
        _ = await first?.value
        await eventually { api.edits.count == 2 }
        response.content = "local-B"
        response.editedTimestamp = "2026-11-01T00:00:01.123999Z"
        api.answerEdit(1, with: response)
        _ = await second?.value
        XCTAssertEqual(timeline.messages[1].content, "local-B")
        XCTAssertEqual(timeline.messages[1].editedTimestamp, response.editedTimestamp)
    }

    /// Discarding a failed send removes it locally and forgets its payload.
    func testDiscardFailedSend() {
        let model = AppModel()
        var echo = Message(id: Snowflake.at(.now), channelID: 3, guildID: nil, author: me, content: "lost", timestamp: "")
        echo.nonce = "n3"
        let timeline = model.timeline(for: 3)
        timeline.addPending(echo)
        timeline.markFailed(nonce: "n3", error: "offline")
        model.discard(echo)
        XCTAssertTrue(timeline.messages.isEmpty)
        XCTAssertNil(timeline.sendState(for: echo))
    }
}

@MainActor
final class ListResizeTests: XCTestCase {
    func testKeyboardTransitionDoesNotCountAsReaderScroll() async throws {
        let mock = MockDiscord()
        let store = DiscordStore()
        let timeline = MessageTimeline(channelID: MockDiscord.generalChannel)
        await timeline.loadLatest(api: mock, store: store)
        let list = MessageListController(timeline: timeline, store: store, api: mock, guildID: nil, title: "t", subtitle: "s",
                                         icon: "number", anchor: nil, unreadAfter: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 382, height: 588))
        window.rootViewController = list
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let collection = try XCTUnwrap(list.collectionView)
        let bottom = collection.contentOffset.y
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        collection.contentOffset.y -= 200
        list.scrollViewDidScroll(collection)
        XCTAssertEqual(list.captureAnchor()?.pinnedToBottom, true)
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        list.viewDidLayoutSubviews()
        XCTAssertEqual(collection.contentOffset.y, bottom, accuracy: 0.5)
    }

    func testNonTouchScrollFromBottomStopsFollowing() async throws {
        let mock = MockDiscord()
        let store = DiscordStore()
        let timeline = MessageTimeline(channelID: MockDiscord.generalChannel)
        await timeline.loadLatest(api: mock, store: store)
        let list = MessageListController(timeline: timeline, store: store, api: mock, guildID: nil, title: "t", subtitle: "s",
                                         icon: "number", anchor: nil, unreadAfter: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 382, height: 588))
        window.rootViewController = list
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let collection = try XCTUnwrap(list.collectionView)
        let reading = collection.contentOffset.y - 200
        XCTAssertGreaterThan(reading, 0)
        list.scrollToHistoryOffset(reading)
        list.scrollViewDidScroll(collection)
        XCTAssertEqual(list.captureAnchor()?.pinnedToBottom, false)
        list.viewDidLayoutSubviews()
        XCTAssertEqual(collection.contentOffset.y, reading, accuracy: 0.5)
        var appended = try XCTUnwrap(timeline.messages.last)
        appended.id = Snowflake(appended.id.raw + 1)
        timeline.receive(appended)
        list.viewDidLayoutSubviews()
        XCTAssertEqual(collection.contentOffset.y, reading, accuracy: 0.5, "new messages must not steal the reading position")
    }

    /// Batch 1 leftover: returning to a channel scrolled into history, the
    /// history strip animating in shrank the list and shifted rows by about
    /// half the change (~30-40 pt per visit). The top row must stay put.
    func testShorterListKeepsTopRow() async throws {
        let mock = MockDiscord()
        let store = DiscordStore()
        let timeline = MessageTimeline(channelID: MockDiscord.generalChannel)
        await timeline.loadLatest(api: mock, store: store)
        let middle = timeline.messages[timeline.messages.count / 2].id
        let anchor = ScrollAnchor(itemID: "m\(middle)", offset: -10, pinnedToBottom: false)
        let list = MessageListController(timeline: timeline, store: store, api: mock, guildID: nil, title: "t", subtitle: "s",
                                         icon: "number", anchor: anchor, unreadAfter: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 382, height: 588))
        window.rootViewController = list
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let collection = try XCTUnwrap(list.collectionView)
        let top = collection.contentOffset.y
        XCTAssertGreaterThan(top, 0, "restored into history, not at the top")
        // What the animated resize did on the simulator: one bounds update with
        // a shorter height and the offset nudged down by half the change.
        collection.bounds = CGRect(x: 0, y: top + 30, width: 382, height: 528)
        // The scroll callback that change produces in the app (an offscreen
        // test window doesn't always send it; a repeat is a no-op).
        list.scrollViewDidScroll(collection)
        XCTAssertEqual(collection.contentOffset.y, top, accuracy: 0.5)
        // The reader's own scrolling is never undone.
        collection.contentOffset.y = top + 100
        XCTAssertEqual(collection.contentOffset.y, top + 100, accuracy: 0.5)
    }

    /// Code review 10, finding 5: a resize that didn't move the list, then
    /// a scroll that isn't a touch (VoiceOver, a jump): the scroll stays.
    func testScrollAfterUnmovedResizeStays() async throws {
        let mock = MockDiscord()
        let store = DiscordStore()
        let timeline = MessageTimeline(channelID: MockDiscord.generalChannel)
        await timeline.loadLatest(api: mock, store: store)
        let middle = timeline.messages[timeline.messages.count / 2].id
        let anchor = ScrollAnchor(itemID: "m\(middle)", offset: -10, pinnedToBottom: false)
        let list = MessageListController(timeline: timeline, store: store, api: mock, guildID: nil, title: "t", subtitle: "s",
                                         icon: "number", anchor: anchor, unreadAfter: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 382, height: 588))
        window.rootViewController = list
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let collection = try XCTUnwrap(list.collectionView)
        let top = collection.contentOffset.y
        XCTAssertGreaterThan(top, 0)
        // Shorter, offset unchanged: nothing to correct.
        collection.bounds = CGRect(x: 0, y: top, width: 382, height: 528)
        list.scrollViewDidScroll(collection)
        XCTAssertEqual(collection.contentOffset.y, top, accuracy: 0.5)
        // A programmatic scroll at the new height.
        collection.contentOffset.y = top + 200
        list.scrollViewDidScroll(collection)
        XCTAssertEqual(collection.contentOffset.y, top + 200, accuracy: 0.5, "not mistaken for resize drift")
    }
}
