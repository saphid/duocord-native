import XCTest
import SwiftUI
import UIKit
@testable import DuocordNative

@MainActor
final class Review11ComposerTests: XCTestCase {
    private func sam(_ id: UInt64) -> Autocomplete.Suggestion {
        .member(User(id: Snowflake(id), username: "sam", globalName: "Sam", discriminator: nil, avatar: nil, bot: nil), name: "Sam")
    }

    private func type(_ replacement: String, replacing range: NSRange, in model: AppModel) {
        model.selectedChannel = 1
        let input = ComposerTextInput(draft: Binding(get: { model.drafts[1]! }, set: { model.drafts[1] = $0 }),
                                      model: model, channelID: 1, wantsFocus: false,
                                      maximumLines: 6, hasSuggestions: false, handleKey: { _ in .ignored })
        let coordinator = input.makeCoordinator()
        let view = ComposerTextInput.Input()
        view.text = model.drafts[1]!.text
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: range, replacementText: replacement))
        view.text = (view.text as NSString).replacingCharacters(in: range, with: replacement)
        coordinator.textViewDidChange(view)
    }

    func testDeletingFirstSameNameMentionKeepsSecondIdentity() throws {
        let model = AppModel()
        model.drafts[1] = Draft(text: "@s")
        model.apply(sam(1), for: Autocomplete.query(in: "@s", cursor: 2)!, in: 1)
        model.drafts[1]?.text += "and @s"
        let text = try XCTUnwrap(model.drafts[1]?.text)
        model.apply(sam(2), for: Autocomplete.query(in: text, cursor: text.count)!, in: 1)
        type("", replacing: NSRange(location: 0, length: 5), in: model)
        XCTAssertEqual(model.outgoingText(model.drafts[1]!, in: 1), "and <@2>")
    }

    func testInsertingSameNameBeforeExistingMentionKeepsIdentities() {
        let model = AppModel()
        model.drafts[1] = Draft(text: "@s")
        model.apply(sam(1), for: Autocomplete.query(in: "@s", cursor: 2)!, in: 1)
        type("@s then ", replacing: NSRange(location: 0, length: 0), in: model)
        model.apply(sam(2), for: Autocomplete.query(in: "@s then @Sam ", cursor: 2)!, in: 1)
        XCTAssertEqual(model.outgoingText(model.drafts[1]!, in: 1), "<@2> then <@1>")
    }

    func testReadableMentionDoesNotConvertLiteralSameName() {
        let readable = Autocomplete.readable("<@1> then @Sam", user: { _ in "Sam" }, role: { _ in nil }, channel: { _ in nil })
        XCTAssertEqual(Autocomplete.wireText(readable.text, tokens: readable.tokens), "<@1> then @Sam")
    }

    func testNativeDeletionDistinguishesIdenticalAdjacentMentions() {
        let model = AppModel()
        let readable = Autocomplete.readable("<@1> <@2> ", user: { _ in "Sam" }, role: { _ in nil }, channel: { _ in nil })
        model.drafts[1] = Draft(text: readable.text, tokens: readable.tokens)
        type("", replacing: NSRange(location: 0, length: 5), in: model)
        XCTAssertEqual(model.outgoingText(model.drafts[1]!, in: 1), "<@2>")
        model.drafts[1] = Draft(text: readable.text, tokens: readable.tokens)
        type("", replacing: NSRange(location: 5, length: 5), in: model)
        XCTAssertEqual(model.outgoingText(model.drafts[1]!, in: 1), "<@1>")
        // A String-only replacement cannot tell these deletions apart.
        // Preserve literal text rather than borrowing either person's ID.
        model.drafts[1] = Draft(text: readable.text, tokens: readable.tokens)
        model.drafts[1]?.text = "@Sam "
        XCTAssertEqual(model.outgoingText(model.drafts[1]!, in: 1), "@Sam")
    }

    func testNativeEditsUseCharacterRangesAfterMultiScalarEmoji() {
        let model = AppModel()
        let readable = Autocomplete.readable("👩🏽‍💻 <@1> and <@2>", user: { _ in "Sam" }, role: { _ in nil }, channel: { _ in nil })
        model.drafts[1] = Draft(text: readable.text, tokens: readable.tokens)
        type("Pat", replacing: NSRange(location: "👩🏽‍💻 @".utf16.count, length: 3), in: model)
        XCTAssertEqual(model.outgoingText(model.drafts[1]!, in: 1), "👩🏽‍💻 @Pat and <@2>")
    }

    func testGraphemeJoiningBeforeIdenticalEmojiMentionsPreservesIdentities() {
        let model = AppModel()
        let readable = Autocomplete.readable("👩 👩<@1><@2>", user: { _ in "👩" }, role: { _ in nil }, channel: { _ in nil })
        model.drafts[1] = Draft(text: readable.text, tokens: readable.tokens)
        type("\u{200D}", replacing: NSRange(location: 2, length: 1), in: model)
        XCTAssertEqual(model.outgoingText(model.drafts[1]!, in: 1), "👩‍👩<@1><@2>")
    }

    func testCombiningAccentBeforeMentionKeepsIdentity() {
        let model = AppModel()
        let readable = Autocomplete.readable("e <@1>", user: { _ in "Sam" }, role: { _ in nil }, channel: { _ in nil })
        model.drafts[1] = Draft(text: readable.text, tokens: readable.tokens)
        type("\u{0301}", replacing: NSRange(location: 1, length: 0), in: model)
        XCTAssertEqual(model.outgoingText(model.drafts[1]!, in: 1), "e\u{0301} <@1>")
    }
}

/// Composer autocomplete (GAPS P0-8): finding the query at the cursor,
/// ranking, and the wire form Discord receives.
final class AutocompleteQueryTests: XCTestCase {
    private func query(_ text: String, cursor: Int? = nil) -> Autocomplete.Query? {
        Autocomplete.query(in: text, cursor: cursor ?? text.count)
    }

    func testTriggersAtCursor() {
        XCTAssertEqual(query("hi @al"), .init(trigger: .mention, text: "al", range: 3..<6))
        XCTAssertEqual(query("@"), .init(trigger: .mention, text: "", range: 0..<1), "a bare @ lists members")
        XCTAssertEqual(query("#gen"), .init(trigger: .channel, text: "gen", range: 0..<4))
        XCTAssertEqual(query("so :fi"), .init(trigger: .emoji, text: "fi", range: 3..<6))
        XCTAssertEqual(query("(@al"), .init(trigger: .mention, text: "al", range: 1..<4), "punctuation is a boundary")
        // Mid-word cursor: the query is what's before it; the whole word is replaced.
        XCTAssertEqual(query("hey @auror and", cursor: 8), .init(trigger: .mention, text: "aur", range: 4..<10))
        // A second line.
        XCTAssertEqual(query("first\n@bra"), .init(trigger: .mention, text: "bra", range: 6..<10))
    }

    func testWordBoundaries() {
        XCTAssertNil(query("email@al"), "inside a word")
        XCTAssertNil(query("@al "), "the word ended")
        XCTAssertNil(query("@al", cursor: 0), "cursor before the trigger")
        XCTAssertNil(query(":f"), "emoji need two characters")
        XCTAssertNil(query("at 12:30"), "times aren't emoji")
        XCTAssertNil(query("https://x.com"), "nor URLs")
        XCTAssertNil(query("a:fi"))
        XCTAssertNil(query(":fi:"), "a closed shortcode")
        XCTAssertNil(query("# Title"), "a heading, not a channel")
        XCTAssertNil(query("@@al"))
        XCTAssertNil(query(":fi re"))
    }

    func testIgnoredInsideCode() {
        XCTAssertNil(query("`@al"), "an open inline code span")
        XCTAssertNil(query("`code @al"))
        XCTAssertNil(query("```\nlet x = @al"), "an open code block")
        XCTAssertNil(query("```swift\n:fi"))
        XCTAssertEqual(query("`x` @al")?.text, "al", "after a closed span")
        XCTAssertEqual(query("```a``` #ge")?.text, "ge", "after a closed block")
        XCTAssertEqual(query("\\` @al")?.text, "al", "an escaped backtick isn't code")
    }

    func testInsertReplacesWordAndSpaces() {
        let result = Autocomplete.insert("@Aurora", replacing: 4..<7, in: "hey @au")
        XCTAssertEqual(result.text, "hey @Aurora ")
        XCTAssertEqual(result.cursor, 12)
        // Mid-text: the rest of the word goes, an existing space is reused.
        let middle = Autocomplete.insert("#general", replacing: 3..<7, in: "in #gen now")
        XCTAssertEqual(middle.text, "in #general now")
        XCTAssertEqual(middle.cursor, 12)
    }
}

final class AutocompleteRankingTests: XCTestCase {
    private func user(_ id: UInt64, _ username: String, _ global: String?) -> User {
        User(id: Snowflake(id), username: username, globalName: global, discriminator: "0", avatar: nil, bot: false)
    }

    private lazy var people: [Autocomplete.MentionCandidate] = [
        .init(user: user(1, "aurora", "Aurora"), name: "Aurora", nick: nil, recency: nil),
        .init(user: user(2, "alice", "Alice"), name: "Alice", nick: nil, recency: nil),
        .init(user: user(3, "alistair", "Alistair"), name: "Al", nick: "Al", recency: nil),
        .init(user: user(4, "delta", "Delta Ray"), name: "Delta Ray", nick: nil, recency: nil),
        .init(user: user(5, "zoe", "Zoë"), name: "Zoë", nick: nil, recency: nil),
        .init(user: user(6, "harbor", "Harbor Lights"), name: "Harbs", nick: "Harbs", recency: nil),
        .init(user: user(7, "alba", "Alba"), name: "Alba", nick: nil, recency: 0),
    ]

    private func names(_ query: String) -> [String] {
        Autocomplete.rankMembers(people, query: query, limit: 10).map(\.name)
    }

    func testMemberRanking() {
        // Exact first; then prefixes, the recent author first; then the rest alphabetically.
        XCTAssertEqual(names("al"), ["Al", "Alba", "Alice"])
        XCTAssertEqual(names("AL"), ["Al", "Alba", "Alice"], "case-insensitive")
        XCTAssertEqual(names("ray"), ["Delta Ray"], "a later word")
        XCTAssertEqual(names("zoe"), ["Zoë"], "diacritic-insensitive")
        XCTAssertEqual(names("harbor"), ["Harbs"], "username and global name match under a nickname")
        XCTAssertEqual(names("alis"), ["Al"], "the username behind a nickname")
        XCTAssertEqual(names("ror"), ["Aurora"], "contains, last")
        XCTAssertEqual(names("").first, "Alba", "a bare @: recent authors first")
        XCTAssertEqual(Autocomplete.rankMembers(people, query: "", limit: 3).count, 3)
    }

    func testRolesAndMassMentions() {
        let roles = [Role(id: 10, name: "Designers", color: 0xEB459E, position: 1, mentionable: true),
                     Role(id: 11, name: "Moderators", color: 0, position: 2)]
        let allowed = Autocomplete.mentionSuggestions(members: people, roles: roles, massMentions: true, query: "")
        XCTAssertEqual(allowed.count, 10)
        XCTAssertEqual(allowed.suffix(3).map(\.id), ["r11", "r10", "meveryone"], "people, then roles by position, then @everyone")
        let ev = Autocomplete.mentionSuggestions(members: people, roles: roles, massMentions: true, query: "ev")
        XCTAssertEqual(ev.map(\.id), ["meveryone"])
        XCTAssertEqual(Autocomplete.mentionSuggestions(members: people, roles: roles, massMentions: false, query: "he").map(\.id), [],
                       "@here only where permitted")
        XCTAssertEqual(Autocomplete.mentionSuggestions(members: people, roles: roles, massMentions: true, query: "he").map(\.id), ["mhere"])
        XCTAssertEqual(Autocomplete.mentionSuggestions(members: people, roles: roles, massMentions: false, query: "des").map(\.id), ["r10"])
    }

    func testEmojiRanking() {
        let custom = [Emoji(id: 1003, name: "ship_it", animated: false), Emoji(id: 1006, name: "fire_fold", animated: false),
                      Emoji(id: 1007, name: "fidget_hinge", animated: true)]
        let results = Autocomplete.emojiSuggestions(custom: custom, unicode: Autocomplete.standardEntries, recent: [], query: "fi")
        XCTAssertEqual(results.prefix(2).map(\.id), ["e1006", "e1007"], "the server's emoji first")
        XCTAssertEqual(results.count, 10)
        // Standard emoji: shortest names first; popular ones (passed as recents) lead.
        let standard = results.dropFirst(2).compactMap { if case .emoji(let emoji, let name) = $0 { (emoji.name ?? "", name) } else { nil } }
        XCTAssertEqual(standard.prefix(2).map(\.1), ["fish", "fire"])
        let popular = Autocomplete.emojiSuggestions(custom: custom, unicode: Autocomplete.standardEntries, recent: ["🔥"], query: "fi")
        if case .emoji(let emoji, let name) = popular[2] { XCTAssertEqual(emoji.name, "🔥"); XCTAssertEqual(name, "fire") } else { XCTFail() }
        // Recently used rises within its tier.
        let recent = Autocomplete.emojiSuggestions(custom: custom, unicode: Autocomplete.standardEntries,
                                                   recent: ["fidget_hinge:1007"], query: "fi")
        XCTAssertEqual(recent.first?.id, "e1007")
        // Shortcodes with underscores match standard names with spaces.
        let heart = Autocomplete.emojiSuggestions(custom: [], unicode: Autocomplete.standardEntries, recent: [], query: "red_heart")
        if case .emoji(let emoji, let code) = heart.first { XCTAssertEqual(emoji.name, "❤️"); XCTAssertEqual(code, "red_heart") } else { XCTFail() }
        XCTAssertEqual(Autocomplete.emojiSuggestions(custom: custom, unicode: [], recent: [], query: "hin").map(\.id), ["e1007"], "a later word")
    }

    func testChannelRanking() {
        let channels = ["welcome", "general", "gear", "fold-ideas", "general-archive", "regenerate"].enumerated().map { index, name in
            Channel(id: Snowflake(UInt64(100 + index)), type: .text, guildID: 1, name: name)
        }
        let names = Autocomplete.channelSuggestions(channels, query: "gen").compactMap { suggestion -> String? in
            if case .channel(let channel) = suggestion { return channel.name } else { return nil }
        }
        XCTAssertEqual(names, ["general", "general-archive", "regenerate"])
        XCTAssertEqual(Autocomplete.channelSuggestions(channels, query: "ideas").map(\.id), ["c103"])
        XCTAssertEqual(Autocomplete.channelSuggestions(channels, query: "").count, 6)
    }
}

final class AutocompleteWireTests: XCTestCase {
    private func wire(_ text: String) -> String {
        var tokens: [ComposerToken] = []
        var start = text.startIndex
        while let range = text.range(of: "@Aurora", range: start..<text.endIndex) {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            tokens.append(ComposerToken(display: "@Aurora", wire: "<@100>", range: offset..<(offset + 7)))
            start = range.upperBound
        }
        return Autocomplete.wireText(text, tokens: tokens)
    }

    func testMentionsBecomeWireForm() {
        XCTAssertEqual(wire("hey @Aurora how"), "hey <@100> how")
        XCTAssertEqual(wire("@Aurora"), "<@100>")
        XCTAssertEqual(wire("hi @Aurora, @Aurora!"), "hi <@100>, <@100>!")
        XCTAssertEqual(wire("hey @Auror"), "hey @Auror")
        XCTAssertEqual(wire("@Auroras"), "@Auroras", "not inside a longer word")
        XCTAssertEqual(wire("x@Aurora"), "x@Aurora")
        XCTAssertEqual(wire("`@Aurora` @Aurora"), "`@Aurora` <@100>", "code stays literal")
        XCTAssertEqual(wire("```\n@Aurora\n```"), "```\n@Aurora\n```")
        XCTAssertEqual(wire("`open @Aurora"), "`open <@100>", "an unclosed backtick isn't code on send")
    }

    func testRolesChannelsAndEmoji() {
        let tokens = [ComposerToken(display: "@Designers", wire: "<@&910000000000000901>", range: 0..<10),
                      ComposerToken(display: "#general", wire: "<#910000000000000102>", range: 15..<23),
                      ComposerToken(display: ":ship_it:", wire: "<:ship_it:1003>", range: 24..<33),
                      ComposerToken(display: ":party_parrot:", wire: "<a:party_parrot:1004>", range: 33..<47)]
        XCTAssertEqual(Autocomplete.wireText("@Designers see #general :ship_it::party_parrot:", tokens: tokens),
                       "<@&910000000000000901> see <#910000000000000102> <:ship_it:1003><a:party_parrot:1004>")
        XCTAssertEqual(Autocomplete.wireText("#general-old", tokens: tokens), "#general-old", "channel names continue with hyphens")
    }

    func testSuggestionInsertions() {
        let user = User(id: 5, username: "ember", globalName: "Ember", discriminator: "0", avatar: nil, bot: false)
        XCTAssertTrue(Autocomplete.Suggestion.member(user, name: "Ember").insertion == ("@Ember", "<@5>"))
        XCTAssertTrue(Autocomplete.Suggestion.role(Role(id: 9, name: "Mods", color: 0, position: 1)).insertion == ("@Mods", "<@&9>"))
        XCTAssertTrue(Autocomplete.Suggestion.mass("here").insertion == ("@here", nil), "sent as typed")
        XCTAssertTrue(Autocomplete.Suggestion.emoji(Emoji(id: 7, name: "wave", animated: true), name: "wave").insertion == (":wave:", "<a:wave:7>"))
        XCTAssertTrue(Autocomplete.Suggestion.emoji(Emoji(id: 8, name: "hinge", animated: false), name: "hinge").insertion == (":hinge:", "<:hinge:8>"))
        XCTAssertTrue(Autocomplete.Suggestion.emoji(Emoji(id: nil, name: "🔥", animated: false), name: "fire").insertion == ("🔥", nil))
        let channel = Channel(id: 42, type: .text, guildID: 1, name: "gear")
        XCTAssertTrue(Autocomplete.Suggestion.channel(channel).insertion == ("#gear", "<#42>"))
    }

    func testSameNameMapsByOccurrence() {
        let sams = [ComposerToken(display: "@Sam", wire: "<@1>", range: 0..<4),
                    ComposerToken(display: "@Sam", wire: "<@2>", range: 9..<13)]
        XCTAssertEqual(Autocomplete.wireText("@Sam and @Sam", tokens: sams), "<@1> and <@2>")
        let deltas = [ComposerToken(display: "@Delta", wire: "<@3>", range: 12..<18),
                      ComposerToken(display: "@Delta Ray", wire: "<@4>", range: 0..<10)]
        XCTAssertEqual(Autocomplete.wireText("@Delta Ray, @Delta", tokens: deltas), "<@4>, <@3>")
    }

    func testTypedShortcodes() {
        let resolve: (String) -> String? = { ["fire": "🔥", "ship_it": "<:ship_it:1003>"][$0] }
        XCTAssertEqual(Autocomplete.replacingShortcodes(in: ":fire: :ship_it: :nope:", resolve: resolve), "🔥 <:ship_it:1003> :nope:")
        XCTAssertEqual(Autocomplete.replacingShortcodes(in: "<:ship_it:1003> `:fire:`", resolve: resolve), "<:ship_it:1003> `:fire:`",
                       "existing tokens and code untouched")
        XCTAssertEqual(Autocomplete.replacingShortcodes(in: "at 12:30 and 14:00:", resolve: resolve), "at 12:30 and 14:00:")
        XCTAssertEqual(Autocomplete.standardEmoji["fire"], "🔥")
    }

    func testReadableRoundTrip() {
        let wire = "<@100> and <@!101> see <#102> for <@&103> :) <:ship_it:1003><a:party:1004> `<@100>` <@999>"
        let readable = Autocomplete.readable(wire, user: { ["100": "Aurora", "101": "Bram"][$0.description] },
                                             role: { $0 == 103 ? "Designers" : nil }, channel: { $0 == 102 ? "general" : nil })
        XCTAssertEqual(readable.text, "@Aurora and @Bram see #general for @Designers :) :ship_it::party: `<@100>` <@999>")
        XCTAssertEqual(Autocomplete.wireText(readable.text, tokens: readable.tokens),
                       "<@100> and <@!101> see <#102> for <@&103> :) <:ship_it:1003><a:party:1004> `<@100>` <@999>")
    }
}

/// The model side: where candidates come from, permissions, and what a send carries.
@MainActor
final class AutocompleteModelTests: XCTestCase {
    private let general = MockDiscord.generalChannel

    private func model() -> (AppModel, MockDiscord) {
        let mock = MockDiscord()
        let model = AppModel()
        model.store.apply(ready: mock.readyPayload())
        return (model, mock)
    }

    /// A member search answer, as the mock gateway sends it for "al".
    private func chunk(_ mock: MockDiscord, guild: Snowflake) throws -> GatewayDispatch {
        struct Chunk: Encodable { var guild_id: Snowflake; var members: [Member] }
        struct Envelope: Encodable { var d: Chunk }
        let found = mock.searchableMembers.filter { $0.user?.username.hasPrefix("al") == true }
        return GatewayDispatch(name: "GUILD_MEMBERS_CHUNK", data: try JSONEncoder().encode(Envelope(d: Chunk(guild_id: guild, members: found))))
    }

    func testComposeMentionChannelEmojiAndSend() throws {
        let (model, mock) = model()
        let channel = try XCTUnwrap(model.store.channel(general))
        let guild = try XCTUnwrap(channel.guildID)
        model.store.handle(try chunk(mock, guild: guild))
        let alice = try XCTUnwrap(mock.searchableMembers.first?.user)

        // "@al" → Alice (found by the member search).
        model.drafts[general] = Draft(text: "hi @al")
        let mention = try XCTUnwrap(Autocomplete.query(in: "hi @al", cursor: 6))
        let people = model.suggestions(for: mention, in: channel)
        XCTAssertTrue(people.contains(.member(alice, name: "Alice")))
        XCTAssertTrue(people.contains { if case .member(_, "Al") = $0 { true } else { false } }, "nickname match")
        var cursor = model.apply(.member(alice, name: "Alice"), for: mention, in: general)
        XCTAssertEqual(model.drafts[general]?.text, "hi @Alice ")
        XCTAssertEqual(cursor, 10)

        // "#gen" → #general.
        model.drafts[general]?.text += "in #gen"
        var text = try XCTUnwrap(model.drafts[general]?.text)
        let hash = try XCTUnwrap(Autocomplete.query(in: text, cursor: text.count))
        let channels = model.suggestions(for: hash, in: channel)
        XCTAssertEqual(channels.first, .channel(channel))
        cursor = model.apply(channels[0], for: hash, in: general)

        // ":ship" → the server's :ship_it:.
        model.drafts[general]?.text += ":ship"
        text = try XCTUnwrap(model.drafts[general]?.text)
        let colon = try XCTUnwrap(Autocomplete.query(in: text, cursor: text.count))
        let emoji = model.suggestions(for: colon, in: channel)
        guard case .emoji(let shipIt, "ship_it")? = emoji.first else { return XCTFail("server emoji first: \(emoji)") }
        model.apply(emoji[0], for: colon, in: general)
        XCTAssertEqual(model.drafts[general]?.text, "hi @Alice in #general :ship_it: ")
        XCTAssertEqual(model.settings.recentEmoji.first?.reactionKey, shipIt.reactionKey, "picked emoji become recent")

        let wire = "hi <@\(alice.id)> in <#\(general)> <:ship_it:\(shipIt.id!)>"
        XCTAssertEqual(model.outgoingText(model.drafts[general]!, in: general), wire)
        // Sending puts the wire form on the message (the local echo shows it at once).
        model.send(in: general)
        XCTAssertEqual(model.timeline(for: general).messages.last?.content, wire)
        XCTAssertEqual(model.drafts[general], Draft(), "the draft and its tokens are cleared")
    }

    func testMentionPermissions() throws {
        let (model, mock) = model()
        let at = try XCTUnwrap(Autocomplete.query(in: "@", cursor: 1))
        // Duo Design Lab: your Designers role may mention everyone (and every role).
        let lab = try XCTUnwrap(model.store.channel(general))
        let labIDs = model.suggestions(for: at, in: lab).map(\.id)
        XCTAssertTrue(labIDs.contains("meveryone") && labIDs.contains("mhere"))
        let ev = try XCTUnwrap(Autocomplete.query(in: "@mod", cursor: 4))
        XCTAssertEqual(model.suggestions(for: ev, in: lab).map(\.id), ["r\(mock.guilds[0].id.raw + 900)"])
        // Elsewhere: only mentionable roles, no @everyone/@here.
        let other = try XCTUnwrap(mock.guilds[1].channels.first { $0.type == .text })
        let otherIDs = model.suggestions(for: at, in: other).map(\.id)
        XCTAssertTrue(otherIDs.contains("r\(mock.guilds[1].id.raw + 901)"), "Designers is mentionable")
        XCTAssertFalse(otherIDs.contains("r\(mock.guilds[1].id.raw + 900)"), "Moderators isn't")
        XCTAssertFalse(otherIDs.contains("meveryone") || otherIDs.contains("mhere"))
        // DMs: the recipients (and you), no roles; no channel suggestions.
        let dm = mock.dms[0]
        let dmIDs = model.suggestions(for: at, in: dm).map(\.id)
        XCTAssertEqual(Set(dmIDs), Set(["u\(dm.recipients![0].id)", "u\(mock.me.id)"]))
        XCTAssertTrue(model.suggestions(for: Autocomplete.query(in: "#", cursor: 1)!, in: dm).isEmpty)
    }

    func testRecentAuthorsAndThreads() async throws {
        let (model, mock) = model()
        let channel = try XCTUnwrap(model.store.channel(general))
        await model.timeline(for: general).loadLatest(api: mock, store: model.store)
        let newest = try XCTUnwrap(model.timeline(for: general).messages.last { !$0.isSystem })
        let at = try XCTUnwrap(Autocomplete.query(in: "@", cursor: 1))
        guard case .member(let first, _)? = model.suggestions(for: at, in: channel).first else { return XCTFail() }
        XCTAssertEqual(first.id, newest.author.id, "the newest author leads a bare @")
        // Threads the reader can see are offered after their channel.
        let book = try XCTUnwrap(Autocomplete.query(in: "#book", cursor: 5))
        XCTAssertEqual(model.suggestions(for: book, in: channel).map(\.id), ["c\(mock.guilds[0].threads[0].id)"])
    }

    /// Editing shows readable tokens and saving unchanged text sends nothing.
    func testEditRoundTrip() throws {
        let (model, mock) = model()
        let aurora = mock.users[0]
        var mine = Message(id: 50, channelID: general, guildID: mock.guilds[0].id, author: mock.me,
                           content: "<@\(aurora.id)> see <#\(general)> <:ship_it:1003>", timestamp: "")
        mine.mentions = [aurora]
        model.timeline(for: general).receive(mine)
        model.beginEdit(mine)
        XCTAssertEqual(model.drafts[general]?.text, "@Aurora see #general :ship_it:")
        XCTAssertEqual(model.outgoingText(model.drafts[general]!, in: general), mine.content)
        model.drafts[general]?.text = "@Aurora see #general :ship_it: :fire:"
        XCTAssertEqual(model.outgoingText(model.drafts[general]!, in: general), mine.content + " 🔥", "a typed shortcode becomes emoji")
    }

    /// The mock fills mentions from the content, as Discord does.
    func testMockSendFillsMentions() async throws {
        let mock = MockDiscord()
        let alice = try XCTUnwrap(mock.searchableMembers.first?.user)
        let role = Snowflake(mock.guilds[0].id.raw + 901)
        let sent = try await mock.send(channel: general, content: "<@\(alice.id)> <@&\(role)> @here", replyTo: nil, pingReply: false,
                                       attachments: [], nonce: "n")
        XCTAssertEqual(sent.mentions.map(\.id), [alice.id])
        XCTAssertEqual(sent.mentionRoles, [role])
        XCTAssertTrue(sent.mentionEveryone)
        XCTAssertEqual(mock.sent.last?.content, "<@\(alice.id)> <@&\(role)> @here")
        XCTAssertEqual(MockDiscord.ids(in: "<@!5> <@&6> <@7>", prefix: "<@"), [5, 7])
    }
}
