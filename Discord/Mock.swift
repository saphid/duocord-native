import Foundation
import os

/// A deterministic, in-process Discord for performance runs and screenshots:
/// realistic servers, folders, DMs and long image-heavy channels, with no
/// network and no real account. Launch with `-DuocordMock YES`.
final class MockDiscord: DiscordAPI, @unchecked Sendable {
    let me = User(id: 900_000_000_000_000_001, username: "you", globalName: "You", discriminator: "0", avatar: "mock", bot: false)
    let users: [User]
    /// Members only a member search (op 8) finds: not in the member list
    /// sample, as in a large server. Some have server nicknames.
    let searchableMembers: [Member]
    let guilds: [Guild]
    let dms: [Channel]
    private var histories: [Snowflake: [Message]] = [:]
    private let lock = NSLock()
    /// Base for message IDs: about two weeks ago, so days and "Today" vary.
    private let epoch = Date.now.addingTimeInterval(-14 * 86_400)
    static let imageChannel: Snowflake = 910_000_000_000_000_103
    static let generalChannel: Snowflake = 910_000_000_000_000_102

    init() {
        let names = [("aurora", "Aurora"), ("bramble", "Bramble"), ("cinder", "Cinder"), ("delta", "Delta Ray"),
                     ("ember", "Ember"), ("fjord", "Fjord"), ("galen", "Galen"), ("harbor", "Harbor Lights"),
                     ("iris", "Iris"), ("juniper", "Juniper"), ("kestrel", "Kestrel"), ("lumen", "Lumen"),
                     ("mosaic", "Mosaic"), ("nimbus", "Nimbus"), ("orbit-bot", "Orbit")]
        users = names.enumerated().map { index, name in
            User(id: Snowflake(900_000_000_000_000_100 + UInt64(index)), username: name.0, globalName: name.1,
                 discriminator: "0", avatar: index % 5 == 4 ? nil : "mock", bot: name.0.hasSuffix("bot"))
        }
        let searchable: [(String, String, String?)] = [
            ("alice", "Alice", nil), ("alistair", "Alistair", "Al"), ("albatross-bot", "Albatross", nil), ("zoe", "Zoë", nil),
            ("quinn", "Quinn", nil), ("rowan", "Rowan", "Ro"), ("sable", "Sable", nil), ("tamsin", "Tamsin", "Tam"),
            ("ulric", "Ulric", nil), ("vesper", "Vesper", nil), ("willow", "Willow", nil), ("yara", "Yara", nil),
        ]
        searchableMembers = searchable.enumerated().map { index, entry in
            let user = User(id: Snowflake(900_000_000_000_000_200 + UInt64(index)), username: entry.0, globalName: entry.1,
                            discriminator: "0", avatar: "mock", bot: entry.0.hasSuffix("bot"))
            return Member(user: user, nick: entry.2, roles: [])
        }
        let guildSpecs: [(String, [String])] = [
            ("Duo Design Lab", ["welcome", "general", "image-dump", "fold-ideas", "show-and-tell"]),
            ("SwiftUI Collective", ["announcements", "help", "layouts", "performance"]),
            ("Night Owls", ["lounge", "music", "photos"]),
            ("Trail Runners", ["routes", "gear", "race-reports"]),
            ("Pixel Garden", ["art", "critique", "commissions"]),
            ("Home Lab", ["servers", "networking", "automation"]),
            ("Book Club", ["current-read", "spoilers"]),
            ("Coffee Nerds", ["brews", "beans"]),
        ]
        var guilds: [Guild] = []
        for (gIndex, spec) in guildSpecs.enumerated() {
            let guildID = Snowflake(910_000_000_000_000_000 + UInt64(gIndex) * 1000)
            var channels: [Channel] = []
            let textCategory = Channel(id: Snowflake(guildID.raw + 1), type: .category, guildID: guildID, name: "Text Channels", position: 0)
            let voiceCategory = Channel(id: Snowflake(guildID.raw + 2), type: .category, guildID: guildID, name: "Voice", position: 1)
            channels += [textCategory, voiceCategory]
            for (cIndex, name) in spec.1.enumerated() {
                let id = gIndex == 0 ? Snowflake(910_000_000_000_000_101 + UInt64(cIndex)) : Snowflake(guildID.raw + 100 + UInt64(cIndex))
                let type: ChannelType = name == "announcements" ? .announcement : (name == "fold-ideas" ? .forum : .text)
                var channel = Channel(id: id, type: type, guildID: guildID, name: name,
                                      topic: cIndex == 1 ? "Talk about anything. Be kind." : nil, position: cIndex, parentID: textCategory.id)
                channel.lastMessageID = Snowflake.at(Date.now.addingTimeInterval(-Double(cIndex * 900)))
                channels.append(channel)
            }
            channels.append(Channel(id: Snowflake(guildID.raw + 200), type: .voice, guildID: guildID, name: "Lounge", position: 0, parentID: voiceCategory.id))
            channels.append(Channel(id: Snowflake(guildID.raw + 201), type: .voice, guildID: guildID, name: "Focus Room", position: 1, parentID: voiceCategory.id))
            var guild = Guild(id: guildID, name: spec.0, icon: gIndex % 4 == 3 ? nil : "mock",
                              roles: [Role(id: guildID, name: "@everyone", color: 0, position: 0, permissions: String(Permission.viewChannel | Permission.sendMessages | Permission.readHistory | Permission.connect)),
                                      Role(id: Snowflake(guildID.raw + 900), name: "Moderators", color: 0x3BA55C, position: 2, hoist: true),
                                      // You're a Designer: in the first server that lets you
                                      // mention everyone (and every role) and pin; elsewhere only
                                      // mentionable roles appear in autocomplete.
                                      Role(id: Snowflake(guildID.raw + 901), name: "Designers", color: 0xEB459E, position: 1,
                                           permissions: gIndex == 0 ? String(Permission.mentionEveryone | Permission.pinMessages) : "0", hoist: true, mentionable: true),
                                      Role(id: Snowflake(guildID.raw + 902), name: "Night Shift", color: 0xFAA61A, position: 3)],
                              channels: channels)
            guild.memberCount = 1200 + gIndex * 37
            if gIndex == 0 {
                // Custom emoji (mock IDs draw generated images, see `Emoji.url`).
                guild.emojis = ["duo_fold", "hinge", "blurple_heart", "ship_it", "party_parrot", "book_pose",
                                "fire_fold", "fidget_hinge", "first_light", "fold_wave"].enumerated().map { index, name in
                    Emoji(id: Snowflake(1_000 + UInt64(index)), name: name, animated: index == 4 || index == 7)
                }
                // A thread under #general.
                var thread = Channel(id: Snowflake(guildID.raw + 500), type: .publicThread, guildID: guildID, name: "Book pose feedback",
                                     parentID: 910_000_000_000_000_102)
                thread.lastMessageID = Snowflake.at(Date.now.addingTimeInterval(-3600))
                thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
                guild.threads = [thread]
            }
            if gIndex == 1 {
                guild.emojis = ["swift_bird", "layout_grid"].enumerated().map { index, name in
                    Emoji(id: Snowflake(2_000 + UInt64(index)), name: name, animated: false)
                }
            }
            guilds.append(guild)
        }
        self.guilds = guilds
        var dms: [Channel] = []
        for index in 0..<7 {
            var dm = Channel(id: Snowflake(920_000_000_000_000_000 + UInt64(index)), type: index == 6 ? .groupDM : .dm,
                             recipients: index == 6 ? Array(users[0..<3]) : [users[index]])
            if index == 6 { dm.name = "Weekend plans" }
            dm.lastMessageID = Snowflake.at(Date.now.addingTimeInterval(-Double(index) * 5400))
            dms.append(dm)
        }
        self.dms = dms
    }

    /// Stable decode-to-render fixtures, also inserted in the latest general
    /// page. URLs stay on the existing in-process mock image path.
    static func contentParityFixtures() throws -> [Message] {
        try JSONDecoder().decode([Message].self, from: Data(contentParityJSON.utf8))
    }

    /// Offline media exercise: no account, CDN or external video is consulted.
    static func animatedMediaFixtures() -> [Message] {
        let author = User(id: 900_000_000_000_000_100, username: "aurora", globalName: "Aurora", avatar: "mock-animated")
        let base = Message(id: 1_434_105_987_072_000_020, channelID: generalChannel, guildID: 910_000_000_000_000_000, author: author,
                           content: "Native animation <a:pulse:1004> and ||<a:hidden:1004>||", timestamp: "2026-11-01T00:00:00Z")
        var raster = base
        raster.attachments = [Attachment(id: 80, filename: "pulse.gif", size: 1387, url: "mock://animation/pulse.gif",
                                         width: 32, height: 24, contentType: "image/gif", description: "Three color animation")]
        raster.reactions = [Reaction(count: 2, me: false, emoji: Emoji(id: 1004, name: "pulse", animated: true))]
        var gifv = base
        gifv.id = 1_434_105_987_072_000_021
        gifv.content = "A silent native gifv loop; the source fixture deliberately includes audio."
        gifv.embeds = [Embed(type: "gifv", url: "https://example.com/offline-fixture",
                            thumbnail: EmbedMedia(url: "mock://animation/still.png", width: 32, height: 24),
                            video: EmbedMedia(url: Bundle.main.url(forResource: "loop-with-audio", withExtension: "mp4")?.absoluteString, width: 32, height: 24))]
        var sticker = base
        sticker.id = 1_434_105_987_072_000_022
        sticker.content = "An APNG sticker"
        sticker.stickerItems = [StickerItem(id: 84, name: "Pulse sticker", formatType: 2)]
        var spoiler = raster
        spoiler.id = 1_434_105_987_072_000_023
        spoiler.content = "A hidden animated attachment"
        spoiler.attachments[0].filename = "SPOILER_pulse.gif"
        return [raster, gifv, sticker, spoiler]
    }

    static let contentParityJSON = #"""
    [
      {"id":"1434105987072000001","channel_id":"910000000000000102","author":{"id":"900000000000000100","username":"aurora"},
       "content":"A note forwarded from the design channel.","timestamp":"2026-11-01T00:00:00Z",
       "message_reference":{"type":1,"message_id":"1434105987072000000","channel_id":"910000000000000104","guild_id":"910000000000000000"},
       "message_snapshots":[{"message":{"content":"**Keep the question readable.** A snapshot keeps its original text and media.","timestamp":"2026-10-31T22:20:00Z",
         "attachments":[{"id":"41","filename":"fold-study.png","size":1200,"url":"mock://image/forwarded/1200x800","width":1200,"height":800,"content_type":"image/png","description":"Fold study with two readable pages"},
                        {"id":"42","filename":"research-notes.txt","size":320,"url":"mock://file/research-notes.txt"}],
         "embeds":[{"title":"Original research","description":"Text and an **embed** survive forwarding.","url":"https://example.com/research"}],
         "message_snapshots":[{"message":{"content":"An earlier forwarded note.","timestamp":"2026-10-30T20:00:00Z"}}]}}]},
      {"id":"1434105987072000002","channel_id":"910000000000000102","author":{"id":"900000000000000114","username":"orbit-bot","bot":true},
       "content":"","poll":{"question":{"text":"Which layout keeps a long question and every answer readable when the display folds?"},
       "answers":[{"answer_id":1,"poll_media":{"text":"A single, reflowing column","emoji":{"name":"📖"}}},
                  {"answer_id":2,"poll_media":{"text":"A long answer that should wrap at narrow widths instead of disappearing behind a count","emoji":{"id":"2000","name":"swift_bird"}}}],
       "expiry":"2026-11-07T12:00:00Z","allow_multiselect":true,"results":{"is_finalized":false,"answer_counts":[{"id":1,"count":12,"me_voted":true},{"id":2,"count":3}]}}},
      {"id":"1434105987072000003","channel_id":"910000000000000102","author":{"id":"900000000000000101","username":"bramble"},
       "content":"","poll":{"question":{"text":"Tea or coffee?"},"answers":[{"answer_id":1,"poll_media":{"text":"Tea","emoji":{"name":"🍵"}}},{"answer_id":2,"poll_media":{"text":"Coffee","emoji":{"name":"☕"}}}],
       "expiry":"2026-10-31T10:00:00Z","allow_multiselect":false,"results":{"is_finalized":true,"answer_counts":[{"id":1,"count":8},{"id":2,"count":5}]}}},
      {"id":"1434105987072000004","channel_id":"910000000000000102","author":{"id":"900000000000000114","username":"orbit-bot","bot":true},
       "content":"","flags":32768,
       "attachments":[{"id":"43","filename":"fold-gallery.png","size":1500,"url":"mock://image/component-gallery/1000x700","width":1000,"height":700,"content_type":"image/png"},
                      {"id":"44","filename":"layout-notes.txt","size":512,"url":"mock://file/layout-notes.txt"}],
       "components":[{"type":17,"components":[
         {"type":10,"content":"## Field notes\nComponents V2 can carry the entire message. **This text must stay visible.**"},
         {"type":9,"components":[{"type":10,"content":"A section with a thumbnail and long descriptive text that wraps on the outer display."}],"accessory":{"type":11,"media":{"url":"mock://image/thumbnail/320x320","width":320,"height":320},"description":"Section thumbnail"}},
         {"type":12,"items":[{"media":{"url":"attachment://fold-gallery.png"},"description":"A gallery view of the folded layout"},{"media":{"url":"mock://image/component-second/800x600","width":800,"height":600},"description":"A second readable page"}]},
         {"type":13,"file":{"url":"attachment://layout-notes.txt"}},
         {"type":1,"components":[{"type":2,"style":5,"label":"Read the layout notes","url":"https://example.com/layout-notes"},{"type":2,"style":1,"label":"Approve layout","custom_id":"approve"}]},
         {"type":3,"placeholder":"Choose a review topic","options":[{"label":"Readability","value":"readability"},{"label":"Fold behavior","value":"fold"}]},
         {"type":99,"content":"Text in an unknown future component is still readable."}
       ]}]},
      {"id":"1434105987072000005","channel_id":"910000000000000102","author":{"id":"900000000000000114","username":"orbit-bot","bot":true},
       "type":46,"content":"","embeds":[{"type":"poll_result","fields":[{"name":"poll_question_text","value":"Tea or coffee?"},{"name":"victor_answer_text","value":"Tea"},{"name":"total_votes","value":"13"}]}]}
    ]
    """#

    // MARK: READY

    func readyPayload() -> ReadyPayload {
        let members = guilds.map { guild in [Member(user: me, nick: nil, roles: [Snowflake(guild.id.raw + 901)])] }
        var reads: [ReadState] = []
        for guild in guilds {
            for channel in guild.channels where channel.type.isTextLike {
                // A few unread channels with mentions, the rest read.
                let unread = channel.id.raw % 3 == 0
                reads.append(ReadState(id: channel.id, lastMessageID: unread ? Snowflake(1) : channel.lastMessageID,
                                       mentionCount: unread && channel.id.raw % 2 == 0 ? Int(channel.id.raw % 4) + 1 : 0))
            }
        }
        for dm in dms {
            reads.append(ReadState(id: dm.id, lastMessageID: dm.id.raw % 3 == 1 ? Snowflake(1) : dm.lastMessageID,
                                   mentionCount: dm.id.raw % 3 == 1 ? 2 : 0))
        }
        let saved = lock.withLock { (acknowledgedReads, readStateVersion) }
        reads = reads.map { saved.0[$0.id] ?? $0 }
        let known = Set(reads.map(\.id))
        reads += saved.0.values.filter { !known.contains($0.id) }
        var ready = ReadyPayload(user: me, guilds: guilds, privateChannels: dms + lock.withLock { Array(createdDMs.values) }, users: users, mergedMembers: members,
                            readStates: reads, guildSettings: [], settingsProto: Self.foldersProto(guilds: guilds.map(\.id)))
        ready.relationships = peopleReadyRelationships
        ready.readStateVersion = saved.1
        return ready
    }

    /// Guild folders in the protobuf settings shape: one folder of three.
    static func foldersProto(guilds: [Snowflake]) -> String {
        func varint(_ value: UInt64) -> [UInt8] {
            var v = value, out: [UInt8] = []
            repeat { var byte = UInt8(v & 0x7F); v >>= 7; if v != 0 { byte |= 0x80 }; out.append(byte) } while v != 0
            return out
        }
        func field(_ number: Int, _ wire: Int, _ payload: [UInt8]) -> [UInt8] {
            varint(UInt64(number << 3 | wire)) + (wire == 2 ? varint(UInt64(payload.count)) : []) + payload
        }
        func fixed(_ ids: [Snowflake]) -> [UInt8] { ids.flatMap { id in (0..<8).map { UInt8((id.raw >> (8 * UInt64($0))) & 0xFF) } } }
        var folders: [UInt8] = []
        for (index, guild) in guilds.enumerated() where index < 2 {
            folders += field(1, 2, field(1, 2, fixed([guild])))
        }
        let grouped = Array(guilds[2..<5])
        let folder = field(1, 2, fixed(grouped)) + field(2, 2, field(1, 0, varint(42))) + field(3, 2, field(1, 2, Array("Hobbies".utf8)))
            + field(4, 2, field(1, 0, varint(0x5865F2)))
        folders += field(1, 2, folder)
        for guild in guilds[5...] { folders += field(1, 2, field(1, 2, fixed([guild]))) }
        return Data(field(14, 2, folders)).base64EncodedString()
    }

    // MARK: History

    private func history(for channel: Snowflake) -> [Message] {
        lock.lock(); defer { lock.unlock() }
        if let existing = histories[channel] { return existing }
        let generated = generate(channel)
        histories[channel] = generated
        return generated
    }

    private func generate(_ channel: Snowflake) -> [Message] {
        let isImages = channel == Self.imageChannel
        let count = isImages ? 2400 : (channel == Self.generalChannel ? 1800 : 260)
        let primaryFixtures = channel == Self.generalChannel ? (((try? Self.contentParityFixtures()) ?? []) + Self.animatedMediaFixtures()) : []
        var rng = SeededRandom(seed: channel.raw)
        let guildID = guilds.first { $0.channels.contains { $0.id == channel } }?.id
            ?? guilds.flatMap(\.threads).first { $0.id == channel }?.guildID
        let dm = dms.first { $0.id == channel }
        let authors = dm.map { ($0.recipients ?? []) + [me] } ?? users
        let span = Date.now.timeIntervalSince(epoch) - 120
        var messages: [Message] = []
        var time = epoch.timeIntervalSince1970
        var previousAuthor = authors[0]
        for index in 0..<count {
            // Bursty timing: runs of quick replies, then gaps.
            time += rng.chance(0.8) ? Double(rng.int(5...90)) : Double(rng.int(600...3600 * 4))
            let fraction = Double(index) / Double(count)
            let stamp = max(time, epoch.timeIntervalSince1970 + span * fraction)
            let date = Date(timeIntervalSince1970: min(stamp, Date.now.timeIntervalSince1970 - Double(count - index) * 2))
            let author = rng.chance(0.55) ? previousAuthor : authors[rng.int(0...(authors.count - 1))]
            previousAuthor = author
            let id = Snowflake(Snowflake.at(date).raw + UInt64(index % 4096))
            var message = Message(id: id, channelID: channel, guildID: guildID, author: author,
                                  content: isImages && rng.chance(0.55) ? "" : MockText.line(&rng, users: users, me: me),
                                  timestamp: ISO8601DateFormatter().string(from: date))
            if isImages || rng.chance(0.12) {
                let pictures = isImages ? (rng.chance(0.25) ? rng.int(2...4) : 1) : 1
                message.attachments = (0..<pictures).map { p in
                    let sizes = [(1600, 1200), (1080, 1920), (1920, 1080), (1200, 1200), (800, 2000), (2400, 1000), (640, 480)]
                    let size = sizes[rng.int(0...(sizes.count - 1))]
                    let seed = "\(channel)-\(index)-\(p)"
                    return Attachment(id: Snowflake(id.raw + UInt64(p)), filename: "IMG_\(index).jpg", size: 1_200_000,
                                      url: "mock://image/\(seed)/\(size.0)x\(size.1)", proxyURL: "mock://image/\(seed)/\(size.0)x\(size.1)",
                                      width: size.0, height: size.1, contentType: "image/jpeg", description: nil, flags: nil, durationSecs: nil)
                }
            } else if rng.chance(0.03) {
                message.attachments = [Attachment(id: id, filename: "fold-notes-\(index).pdf", size: 240_000 + index, url: "mock://file/\(index)",
                                                  proxyURL: nil, width: nil, height: nil, contentType: "application/pdf",
                                                  description: nil, flags: nil, durationSecs: nil)]
            }
            if rng.chance(isImages ? 0.08 : 0.06) {
                message.embeds = [Embed(type: "rich", title: "Designing for iPhone Duo", description: "What moves, what splits, and what stays when the device folds. **Size classes** first, postures second.",
                                        url: "https://developer.apple.com/iphone-duo/", color: 0x5865F2,
                                        image: rng.chance(0.5) ? EmbedMedia(url: "mock://image/embed-\(index)/1200x630", proxyURL: "mock://image/embed-\(index)/1200x630", width: 1200, height: 630) : nil,
                                        thumbnail: nil, provider: EmbedProvider(name: "Apple Developer", url: nil),
                                        author: nil, fields: rng.chance(0.4) ? [EmbedField(name: "Outer", value: "466 × 678 pt", inline: true), EmbedField(name: "Inner", value: "951 × 669 pt", inline: true)] : nil)]
            }
            if rng.chance(0.18) {
                let emoji = ["👍", "❤️", "😂", "🎉", "👀", "🔥", "✅"]
                message.reactions = (0..<rng.int(1...3)).map { r in
                    Reaction(count: rng.int(1...14), me: r == 0 && rng.chance(0.3), emoji: Emoji(id: nil, name: emoji[(index + r) % emoji.count], animated: false))
                }
            }
            if index > 3, rng.chance(0.08), let target = messages.dropLast().last(where: { !$0.content.isEmpty }) {
                message.referencedMessage = MessageBox(target)
                message.messageReference = MessageReference(messageID: target.id, channelID: channel, guildID: guildID)
                message.type = 19
            }
            if rng.chance(0.02) { message.mentions = [me]; message.content = "<@\(me.id)> " + message.content }
            if rng.chance(0.03) { message.editedTimestamp = message.timestamp }
            // Some of your own messages in server channels (edit and delete
            // checks), chosen without drawing from the generator so the rest
            // of the history is unchanged.
            if dm == nil, !isImages, !message.content.isEmpty, message.mentions.isEmpty, index % 47 == 13 || index == count - 3 {
                message.author = me
            }
            let fixtureIndex = index - (count - 12)
            if primaryFixtures.indices.contains(fixtureIndex) {
                let fixture = primaryFixtures[fixtureIndex]
                let generatedID = message.id
                let generatedTimestamp = message.timestamp
                message = fixture
                message.id = generatedID
                message.timestamp = generatedTimestamp
                message.guildID = guildID
            }
            messages.append(message)
        }
        return messages
    }

    private func page(_ all: [Message], before: Snowflake?, after: Snowflake?, around: Snowflake?, limit: Int) -> [Message] {
        if let around, let index = all.firstIndex(where: { $0.id >= around }) {
            let start = max(0, index - limit / 2)
            return Array(all[start..<min(all.count, start + limit)]).reversed()
        }
        if let after {
            return Array(all.filter { $0.id > after }.prefix(limit)).reversed()
        }
        let candidates = before.map { b in all.filter { $0.id < b } } ?? all
        return Array(candidates.suffix(limit)).reversed()
    }

    // MARK: DiscordAPI

    func messages(channel: Snowflake, before: Snowflake?, after: Snowflake?, around: Snowflake?, limit: Int) async throws -> [Message] {
        #if DEBUG
        let fail = lock.withLock { let value = readHistoryFailure; readHistoryFailure = false; return value }
        if fail { throw DiscordError.http(403, "Mock history refused") }
        #endif
        try await Task.sleep(for: .milliseconds(120))
        let result = page(history(for: channel), before: before, after: after, around: around, limit: limit)
        #if DEBUG
        if let beforeReadHistoryResponse { await beforeReadHistoryResponse() }
        #endif
        return result
    }

    func pins(channel: Snowflake) async throws -> [Message] {
        let all = history(for: channel)
        let derived = generatedPins(all, channel: channel)
        let (overrides, order) = lock.withLock { (pinOverrides[channel] ?? [:], pinOrder[channel] ?? []) }
        guard !overrides.isEmpty else { return derived }
        // Newest pin first, then the generated ones nobody changed.
        let added = order.compactMap { id in all.first { $0.id == id } }
        return added + derived.filter { overrides[$0.id] == nil }
    }

    /// Eight generated pins per channel; the `DuocordMockManyPins` debug launch
    /// argument gives the general channel over 100 so paging can be seen offline.
    private func generatedPins(_ all: [Message], channel: Snowflake) -> [Message] {
        let candidates = all.filter { !$0.content.isEmpty }.enumerated()
        #if DEBUG
        if channel == Self.generalChannel, UserDefaults.standard.bool(forKey: "DuocordMockManyPins") {
            return candidates.filter { $0.offset % 15 == 3 }.map(\.element)
        }
        #endif
        return Array(candidates.filter { $0.offset % 97 == 3 }.map(\.element).prefix(8))
    }

    /// Discord's paged pins: newest first, `before` an exact earlier `pinned_at`.
    /// Written pins keep the time they were pinned; generated ones get fixed
    /// past times, one second apart, older than any write.
    func pinPage(channel: Snowflake, before: String?, limit: Int) async throws -> PinPage {
        try await Task.sleep(for: .milliseconds(120))
        let pins = try await pins(channel: channel)
        let times = lock.withLock { pinTimes }
        let formatter = ISO8601DateFormatter()
        var generated = 0
        let items = pins.map { message -> PinPage.Item in
            if let time = times[message.id] { return PinPage.Item(message: message, pinnedAt: time) }
            defer { generated += 1 }
            return PinPage.Item(message: message, pinnedAt: formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 - Double(generated))))
        }
        var remaining = items[...]
        if let before {
            guard let cutoff = formatter.date(from: before) else { throw DiscordError.http(400, "Invalid Form Body") }
            remaining = remaining.drop { item in item.pinnedAt.flatMap(formatter.date(from:)).map { $0 >= cutoff } ?? true }
        }
        let size = min(max(limit, 1), 50)
        return PinPage(items: Array(remaining.prefix(size)), hasMore: remaining.count > size)
    }

    func search(guild: Snowflake?, channel: Snowflake?, query: String, offset: Int) async throws -> SearchResult {
        try await Task.sleep(for: .milliseconds(250))
        let scope = guild.flatMap { g in guilds.first { $0.id == g }?.channels.filter { $0.type.isTextLike }.map(\.id) } ?? channel.map { [$0] } ?? []
        let hits = scope.flatMap { history(for: $0) }.filter { $0.content.localizedCaseInsensitiveContains(query) }.sorted { $0.id > $1.id }
        return SearchResult(totalResults: hits.count, messages: Array(hits.dropFirst(offset).prefix(25)))
    }

    func mentions(limit: Int, before: Snowflake?) async throws -> [Message] {
        let ids = guilds.prefix(2).flatMap { $0.channels.filter { $0.type == .text }.map(\.id) }
        return Array(ids.flatMap { history(for: $0) }.filter { (before == nil || $0.id < before!) && $0.mentions.contains { $0.id == me.id } }.sorted { $0.id > $1.id }.prefix(limit))
    }

    func forumThreads(channel: Snowflake, offset: Int) async throws -> ThreadSearchResult {
        let titles = ["Book pose: where should the composer go?", "Table-top layout sketches", "Closed display density",
                      "Members panel in split view", "Hinge-aware image viewer", "Dynamic Type at XXL on the outer display"]
        var threads: [Channel] = []
        var firsts: [Message] = []
        for (index, title) in titles.enumerated() {
            let id = Snowflake(channel.raw * 10 + UInt64(index))
            var thread = Channel(id: id, type: .publicThread, guildID: guilds[0].id, name: title, parentID: channel)
            thread.messageCount = 4 + index * 7
            thread.lastMessageID = Snowflake.at(Date.now.addingTimeInterval(-Double(index) * 7200))
            thread.threadMetadata = ThreadMetadata(archived: false, locked: false)
            threads.append(thread)
            firsts.append(Message(id: id, channelID: id, guildID: guilds[0].id, author: users[index % users.count],
                                  content: "Opening thoughts on \(title.lowercased()). What have you tried?", timestamp: ISO8601DateFormatter().string(from: .now)))
        }
        return ThreadSearchResult(threads: threads, firstMessages: firsts, hasMore: false)
    }

    func archivedThreads(channel: Snowflake) async throws -> [Channel] { [] }

    func publicArchivedThreads(channel: Snowflake, before: String?) async throws -> ArchivedThreadPage {
        // Dedicated stable offline fixture, unrelated to live Discord accounts.
        let formatter = ISO8601DateFormatter()
        let cutoff = before.flatMap { formatter.date(from: $0) }
        let rows = (0..<63).map { index -> Channel in
            var thread = Channel(id: Snowflake(channel.raw + 1_000_000 + UInt64(index)), type: .publicThread,
                                 guildID: guilds.first(where: { $0.channels.contains(where: { $0.id == channel }) })?.id,
                                 name: "Archived offline thread \(index + 1)", parentID: channel)
            thread.threadMetadata = ThreadMetadata(archived: true, locked: false,
                archiveTimestamp: formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 - Double(index))))
            return thread
        }.filter { row in
            guard let cutoff else { return before == nil }
            return formatter.date(from: row.threadMetadata!.archiveTimestamp!)! < cutoff
        }
        return ArchivedThreadPage(threads: Array(rows.prefix(25)), hasMore: rows.count > 25)
    }


    // MARK: Writes
    //
    // Each write changes the mock history, then emits the gateway event
    // Discord would send (before the HTTP response, the harder ordering for
    // the app), so mock mode runs the real event paths.

    /// What a send asked for, for tests (allowed mentions on replies).
    struct SentRecord: Equatable {
        var channel: Snowflake
        var content: String
        var replyTo: Snowflake?
        var pingReply: Bool
    }
    private var sentRecords: [SentRecord] = []
    var sent: [SentRecord] { lock.withLock { sentRecords } }

    /// Set by `MockGateway`: delivers a dispatch as if it came from Discord.
    var echo: (@Sendable (GatewayDispatch) -> Void)? {
        get { lock.withLock { echoHandler } }
        set { lock.withLock { echoHandler = newValue } }
    }
    private var echoHandler: (@Sendable (GatewayDispatch) -> Void)?

    private struct Envelope<T: Encodable>: Encodable { var d: T }

    private func emit<T: Encodable>(_ name: String, _ payload: T) {
        guard let echo, let json = try? JSONEncoder().encode(Envelope(d: payload)) else { return }
        echo(GatewayDispatch(name: name, data: json))
    }

    private func guildID(for channel: Snowflake) -> Snowflake? {
        guilds.first { $0.channels.contains { $0.id == channel } || $0.threads.contains { $0.id == channel } }?.id
    }

    /// Debug launch arguments that make writes fail, for rollback checks.
    private func failIfAsked(_ key: String) throws {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: key) { throw DiscordError.http(403, "Missing Permissions") }
        #endif
    }

    #if DEBUG
    private var sendHook: (@Sendable (SentRecord) async throws -> Void)?
    /// Offline tests: runs as a send starts; may hold it or throw to fail it.
    var beforeSend: (@Sendable (SentRecord) async throws -> Void)? {
        get { lock.withLock { sendHook } }
        set { lock.withLock { sendHook = newValue } }
    }
    #endif

    func send(channel: Snowflake, content: String, replyTo: Snowflake?, pingReply: Bool, attachments: [OutgoingAttachment], nonce: String) async throws -> Message {
        #if DEBUG
        if let beforeSend { try await beforeSend(SentRecord(channel: channel, content: content, replyTo: replyTo, pingReply: pingReply)) }
        #endif
        try await Task.sleep(for: .milliseconds(300))
        // `-DuocordMockSendFail YES`: every send fails (the failed-echo menu).
        try failIfAsked("DuocordMockSendFail")
        lock.withLock { sentRecords.append(SentRecord(channel: channel, content: content, replyTo: replyTo, pingReply: pingReply)) }
        var message = Message(id: Snowflake.at(.now), channelID: channel, guildID: guildID(for: channel), author: me, content: content,
                              timestamp: ISO8601DateFormatter().string(from: .now))
        message.nonce = nonce
        // Discord fills these from the content's <@id>, <@&id> and @everyone.
        let known = users + searchableMembers.compactMap(\.user) + [me]
        message.mentions = Self.ids(in: content, prefix: "<@").compactMap { id in known.first { $0.id == id } }
        message.mentionRoles = Self.ids(in: content, prefix: "<@&")
        message.mentionEveryone = content.contains("@everyone") || content.contains("@here")
        if let replyTo, let target = history(for: channel).first(where: { $0.id == replyTo }) {
            message.type = 19
            message.referencedMessage = MessageBox(target)
            message.messageReference = MessageReference(messageID: replyTo, channelID: channel, guildID: message.guildID)
            if pingReply, target.author.id != me.id, !message.mentions.contains(where: { $0.id == target.author.id }) {
                message.mentions.append(target.author)
            }
        }
        record(message)
        emit("MESSAGE_CREATE", message)
        return message
    }

    /// Snowflakes in `<prefix>id>` tokens ("<@" skips role tokens "<@&").
    static func ids(in content: String, prefix: String) -> [Snowflake] {
        content.components(separatedBy: prefix).dropFirst().compactMap { part in
            let digits = part.drop { $0 == "!" }.prefix { $0.isNumber }
            guard !digits.isEmpty, part.drop(while: { $0 == "!" }).dropFirst(digits.count).first == ">" else { return nil }
            return Snowflake(String(digits))
        }
    }

    func record(_ message: Message) {
        _ = history(for: message.channelID) // generate first so the new message extends it
        lock.withLock { histories[message.channelID, default: []].append(message) }
    }

    func edit(channel: Snowflake, message: Snowflake, content: String) async throws -> Message {
        try await Task.sleep(for: .milliseconds(250))
        // `-DuocordMockWriteFail YES`: edits and deletes fail.
        try failIfAsked("DuocordMockWriteFail")
        _ = history(for: channel)
        let edited: Message? = lock.withLock {
            guard var list = histories[channel], let index = list.firstIndex(where: { $0.id == message }),
                  list[index].author.id == me.id else { return nil }
            list[index].content = content
            list[index].editedTimestamp = ISO8601DateFormatter().string(from: .now)
            histories[channel] = list
            return list[index]
        }
        guard let edited else { throw DiscordError.http(403, "Cannot edit a message authored by another user") }
        emit("MESSAGE_UPDATE", edited)
        return edited
    }

    func delete(channel: Snowflake, message: Snowflake) async throws {
        try await Task.sleep(for: .milliseconds(250))
        try failIfAsked("DuocordMockWriteFail")
        _ = history(for: channel)
        let removed: Bool = lock.withLock {
            guard var list = histories[channel], let index = list.firstIndex(where: { $0.id == message }),
                  list[index].author.id == me.id else { return false }
            list.remove(at: index)
            histories[channel] = list
            return true
        }
        guard removed else { throw DiscordError.http(403, "Missing Permissions") }
        struct Deleted: Encodable { var id: Snowflake; var channel_id: Snowflake; var guild_id: Snowflake? }
        emit("MESSAGE_DELETE", Deleted(id: message, channel_id: channel, guild_id: guildID(for: channel)))
    }

    /// A pin write as asked for (recorded before any hook or refusal).
    struct PinRecord: Equatable, Sendable {
        var channel: Snowflake
        var message: Snowflake
        var pinned: Bool
    }
    private var pinRecords: [PinRecord] = []
    var pinOperations: [PinRecord] { lock.withLock { pinRecords } }
    /// Per channel: messages pinned (true) or unpinned (false) by writes, over the generated pins.
    private var pinOverrides: [Snowflake: [Snowflake: Bool]] = [:]
    /// Per channel: written pins, newest first, with when they were pinned.
    private var pinOrder: [Snowflake: [Snowflake]] = [:]
    private var pinTimes: [Snowflake: String] = [:]
    #if DEBUG
    private var pinHook: (@Sendable (PinRecord) async throws -> Void)?
    /// Offline tests: runs as a pin write starts; may hold it or throw to refuse it.
    var beforePin: (@Sendable (PinRecord) async throws -> Void)? {
        get { lock.withLock { pinHook } }
        set { lock.withLock { pinHook = newValue } }
    }
    #endif

    /// Pins as Discord does: CHANNEL_PINS_UPDATE, deliberately no MESSAGE_UPDATE
    /// (the app must not depend on one).
    func setPinned(channel: Snowflake, message: Snowflake, pinned: Bool) async throws {
        let record = PinRecord(channel: channel, message: message, pinned: pinned)
        lock.withLock { pinRecords.append(record) }
        #if DEBUG
        if let hook = lock.withLock({ pinHook }) { try await hook(record) }
        #endif
        try await Task.sleep(for: .milliseconds(200))
        try failIfAsked("DuocordMockWriteFail")
        guard let target = history(for: channel).first(where: { $0.id == message }) else { throw DiscordError.http(404, "Unknown Message") }
        guard !target.isSystem else { throw DiscordError.http(400, "Cannot execute action on a system message") }
        let now = ISO8601DateFormatter().string(from: .now)
        let latest: String? = lock.withLock {
            if let index = histories[channel]?.firstIndex(where: { $0.id == message }) { histories[channel]?[index].pinned = pinned }
            pinOverrides[channel, default: [:]][message] = pinned
            pinOrder[channel, default: []].removeAll { $0 == message }
            if pinned { pinOrder[channel, default: []].insert(message, at: 0); pinTimes[message] = now } else { pinTimes[message] = nil }
            return pinOrder[channel]?.first.flatMap { pinTimes[$0] }
        }
        let remaining = try await pins(channel: channel)
        var event: [String: JSONValue] = ["channel_id": .string(channel.description)]
        if let guild = guildID(for: channel) { event["guild_id"] = .string(guild.description) }
        // Null when no pins remain; omitted when only generated (untimed) pins do.
        if let latest { event["last_pin_timestamp"] = .string(latest) } else if remaining.isEmpty { event["last_pin_timestamp"] = .null }
        emit("CHANNEL_PINS_UPDATE", event)
    }

    struct PeopleRecord: Sendable {
        var method: String
        var route: String
        var fields: [String: JSONValue]?
    }
    static let uncachedFriend = User(id: 900_000_000_000_000_400, username: "uncached.friend", globalName: "Uncached Friend", avatar: "mock")
    static let blockedPerson = User(id: 900_000_000_000_000_401, username: "blocked.person", globalName: "Blocked Person", avatar: "mock")
    private var peopleRecords: [PeopleRecord] = []
    private var relationshipOverrides: [Snowflake: Relationship] = [:]
    private var removedRelationships: Set<Snowflake> = []
    private var createdDMs: [Snowflake: Channel] = [:]
    var peopleOperations: [PeopleRecord] { lock.withLock { peopleRecords } }
    private var peopleReadyRelationships: [Relationship] {
        let defaults = [Relationship(id: users[0].id, type: 1, user: users[0]),
                        Relationship(id: users[1].id, type: 1, user: users[1]),
                        Relationship(id: users[2].id, type: 3, user: users[2]),
                        Relationship(id: users[3].id, type: 4, user: users[3]),
                        Relationship(id: Self.blockedPerson.id, type: 2, user: Self.blockedPerson)]
        return lock.withLock {
            let base = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })
            return Array(base.merging(relationshipOverrides, uniquingKeysWith: { _, new in new }).values)
                .filter { !removedRelationships.contains($0.id) }.sorted { $0.id < $1.id }
        }
    }
    #if DEBUG
    private var peopleFailure = false
    private var peopleResponseHook: (@Sendable (PeopleRecord) async throws -> Void)?
    var failNextPeople: Bool {
        get { lock.withLock { peopleFailure } }
        set { lock.withLock { peopleFailure = newValue } }
    }
    var beforePeopleResponse: (@Sendable (PeopleRecord) async throws -> Void)? {
        get { lock.withLock { peopleResponseHook } }
        set { lock.withLock { peopleResponseHook = newValue } }
    }
    #endif
    private func performPeople(_ record: PeopleRecord) async throws {
        lock.withLock { peopleRecords.append(record) }
        #if DEBUG
        let hook = lock.withLock { peopleResponseHook }
        try await hook?(record)
        let fail = lock.withLock { let result = peopleFailure; peopleFailure = false; return result }
        if fail { throw DiscordError.http(403, "Mock people operation refused") }
        #endif
    }
    func relationship(user: Snowflake, action: RelationshipAction) async throws {
        try await performPeople(PeopleRecord(method: action.method, route: "users/@me/relationships/\(user)", fields: action.body))
        let known = (users + [Self.uncachedFriend, Self.blockedPerson]).first { $0.id == user }
        let result = Relationship(id: user, type: action.resultingType ?? 0, user: known)
        lock.withLock {
            if action.resultingType == nil { removedRelationships.insert(user); relationshipOverrides[user] = nil }
            else { removedRelationships.remove(user); relationshipOverrides[user] = result }
        }
        emit(action.resultingType == nil ? "RELATIONSHIP_REMOVE" : "RELATIONSHIP_ADD", result)
    }
    func requestFriend(username: FriendUsername) async throws {
        try await performPeople(PeopleRecord(method: "POST", route: "users/@me/relationships", fields: username.fields))
        guard let user = (users + [Self.uncachedFriend]).first(where: { $0.username == username.value }) else {
            throw DiscordError.http(404, "Mock username not found")
        }
        guard user.id != me.id else { throw DiscordError.http(400, "Cannot friend yourself") }
        let result = Relationship(id: user.id, type: 4, user: user)
        lock.withLock { relationshipOverrides[user.id] = result; removedRelationships.remove(user.id) }
        emit("RELATIONSHIP_ADD", result)
    }
    func createDM(recipient: Snowflake) async throws -> Channel {
        try await performPeople(PeopleRecord(method: "POST", route: "users/@me/channels", fields: ["recipients": .array([.string(recipient.description)])]))
        if let existing = dms.first(where: { $0.type == .dm && $0.recipients?.map(\.id) == [recipient] }) { return existing }
        if let existing = lock.withLock({ createdDMs[recipient] }) { return existing }
        let user = (users + [Self.uncachedFriend, Self.blockedPerson]).first { $0.id == recipient }
        var channel = Channel(id: Snowflake(930_000_000_000_000_000 + recipient.raw % 1_000_000), type: .dm, recipients: user.map { [$0] })
        channel.recipientIDs = [recipient]
        lock.withLock { createdDMs[recipient] = channel }
        emit("CHANNEL_CREATE", channel)
        return channel
    }

    struct ReadRecord: Sendable {
        var route: String
        var fields: [String: JSONValue]
        var reads: [ReadAcknowledgement]
    }
    private var acknowledgedReads: [Snowflake: ReadState] = [:]
    private var readStateVersion = 0
    private var readRecords: [ReadRecord] = []
    var readOperations: [ReadRecord] { lock.withLock { readRecords } }
    #if DEBUG
    private var readHistoryFailure = false
    private var readHistoryResponseHook: (@Sendable () async -> Void)?
    var beforeReadHistoryResponse: (@Sendable () async -> Void)? {
        get { lock.withLock { readHistoryResponseHook } }
        set { lock.withLock { readHistoryResponseHook = newValue } }
    }
    var failNextReadHistory: Bool {
        get { lock.withLock { readHistoryFailure } }
        set { lock.withLock { readHistoryFailure = newValue } }
    }
    func setReadStates(_ states: [ReadState]) {
        lock.withLock { acknowledgedReads = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) }) }
    }
    private var readFailure = false
    var failNextRead: Bool {
        get { lock.withLock { readFailure } }
        set { lock.withLock { readFailure = newValue } }
    }
    private var readResponseHook: (@Sendable (ReadRecord) async throws -> Void)?
    var beforeReadResponse: (@Sendable (ReadRecord) async throws -> Void)? {
        get { lock.withLock { readResponseHook } }
        set { lock.withLock { readResponseHook = newValue } }
    }
    func setReadHistory(_ messages: [Message], channel: Snowflake) {
        lock.withLock { histories[channel] = messages.sorted { $0.id < $1.id } }
    }
    #endif

    private func performRead(_ record: ReadRecord) async throws {
        lock.withLock { readRecords.append(record) }
        #if DEBUG
        let fail = lock.withLock { let value = readFailure; readFailure = false; return value }
        if fail { throw DiscordError.http(403, "Mock read refused") }
        #endif
        let defaults = Dictionary(uniqueKeysWithValues: readyPayload().readStates.map { ($0.id, $0) })
        for read in record.reads {
            let version = lock.withLock {
                var state = acknowledgedReads[read.channel] ?? defaults[read.channel] ?? ReadState(id: read.channel, lastMessageID: nil, mentionCount: 0)
                state.lastMessageID = read.manual ? read.message : max(read.message, state.lastMessageID ?? 0)
                if let count = read.mentionCount { state.mentionCount = count }
                else if !read.manual { state.mentionCount = 0 }
                acknowledgedReads[read.channel] = state
                readStateVersion += 1
                return readStateVersion
            }
            var fields: [String: JSONValue] = ["channel_id": .string(read.channel.description),
                "message_id": .string(read.message.description), "manual": .bool(read.manual), "version": .number(Double(version))]
            if let count = read.mentionCount { fields["mention_count"] = .number(Double(count)) }
            else if !read.manual { fields["mention_count"] = .number(0) }
            emit("MESSAGE_ACK", fields)
        }
        #if DEBUG
        if let beforeReadResponse { try await beforeReadResponse(record) }
        #endif
    }

    func ack(channel: Snowflake, message: Snowflake) async throws {
        try await acknowledge(ReadAcknowledgement(channel: channel, message: message))
    }
    func acknowledge(_ read: ReadAcknowledgement) async throws {
        try await performRead(ReadRecord(route: "channels/\(read.channel)/messages/\(read.message)/ack", fields: read.fields, reads: [read]))
    }
    func acknowledgeBulk(_ reads: [ReadAcknowledgement]) async throws {
        guard !reads.isEmpty else { return }
        guard reads.allSatisfy({ !$0.manual && $0.message > 0 }) else { throw DiscordError.http(0, "Invalid mock bulk acknowledgement") }
        try await performRead(ReadRecord(route: "read-states/ack-bulk", fields: ["read_states": .array(reads.map(\.bulkFields))], reads: reads))
    }
    func acknowledgeGuild(_ guild: Snowflake) async throws {
        let channels = guilds.first { $0.id == guild }.map { $0.channels + $0.threads } ?? []
        let reads = channels.compactMap { channel -> ReadAcknowledgement? in
            guard let last = channel.lastMessageID else { return nil }
            return ReadAcknowledgement(channel: channel.id, message: last)
        }
        try await performRead(ReadRecord(route: "guilds/\(guild)/ack", fields: [:], reads: reads))
    }
    func typing(channel: Snowflake) async throws {}
    func react(channel: Snowflake, message: Snowflake, emoji: Emoji, add: Bool) async throws {
        // Every request, for checking which writes a burst of taps sends.
        Logger(subsystem: "com.saphid.duocord.native", category: "mock")
            .debug("react \(add ? "add" : "remove", privacy: .public) \(emoji.reactionKey, privacy: .public) on \(message.raw, privacy: .public)")
        try await Task.sleep(for: .milliseconds(reactDelay))
        // `-DuocordMockReactFail YES`: every reaction request fails (rollback checks).
        try failIfAsked("DuocordMockReactFail")
        _ = history(for: channel)
        let changed: Bool = lock.withLock {
            guard var list = histories[channel], let index = list.firstIndex(where: { $0.id == message }) else { return false }
            var reactions = list[index].reactions
            if let existing = reactions.firstIndex(where: { $0.emoji.reactionKey == emoji.reactionKey }) {
                guard reactions[existing].me != add else { return false }
                reactions[existing].me = add
                reactions[existing].count += add ? 1 : -1
                if reactions[existing].count <= 0 { reactions.remove(at: existing) }
            } else if add {
                reactions.append(Reaction(count: 1, me: true, emoji: emoji))
            } else {
                return false
            }
            list[index].reactions = reactions
            histories[channel] = list
            return true
        }
        guard changed else { return }
        struct Reacted: Encodable { var user_id: Snowflake; var channel_id: Snowflake; var message_id: Snowflake; var guild_id: Snowflake?; var emoji: Emoji }
        emit(add ? "MESSAGE_REACTION_ADD" : "MESSAGE_REACTION_REMOVE",
             Reacted(user_id: me.id, channel_id: channel, message_id: message, guild_id: guildID(for: channel), emoji: emoji))
        if reactFailsAfterEcho {
            // The gateway event is handled first; then the response is lost.
            try await Task.sleep(for: .milliseconds(200))
            throw DiscordError.http(502, "Bad Gateway")
        }
    }

    /// `-DuocordMockReactDelay <ms>`: a slower reaction request, so taps
    /// land while one is in flight (the simulator can't tap faster than ~3/s).
    private var reactDelay: Int {
        #if DEBUG
        let delay = UserDefaults.standard.integer(forKey: "DuocordMockReactDelay")
        if delay > 0 { return delay }
        #endif
        return 250
    }

    /// `-DuocordMockReactFailAfterEcho YES`: Discord applies the reaction and
    /// sends its gateway event, but the HTTP response still fails.
    #if DEBUG
    /// Tests set it directly; otherwise the launch argument decides.
    var reactFailsAfterEcho: Bool {
        get { lock.withLock { reactFailAfterEchoOverride } ?? UserDefaults.standard.bool(forKey: "DuocordMockReactFailAfterEcho") }
        set { lock.withLock { reactFailAfterEchoOverride = newValue } }
    }
    private var reactFailAfterEchoOverride: Bool?
    #else
    var reactFailsAfterEcho: Bool { false }
    #endif

    /// The same people for the same message and emoji on every launch; you
    /// come first when you reacted.
    func reactions(channel: Snowflake, message: Snowflake, emoji: Emoji, limit: Int) async throws -> [User] {
        Logger(subsystem: "com.saphid.duocord.native", category: "mock")
            .debug("reactors \(emoji.reactionKey, privacy: .public) on \(message.raw, privacy: .public)")
        try await Task.sleep(for: .milliseconds(200))
        let reaction = history(for: channel).first { $0.id == message }?.reactions.first { $0.emoji.reactionKey == emoji.reactionKey }
        guard let reaction else { return [] }
        var rng = SeededRandom(seed: message.raw ^ UInt64(MockImages.stableHash(emoji.reactionKey)))
        var pool = users
        var others: [User] = []
        let target = min(reaction.count - (reaction.me ? 1 : 0), pool.count)
        while others.count < target {
            others.append(pool.remove(at: rng.int(0...(pool.count - 1))))
        }
        return Array(((reaction.me ? [me] : []) + others).prefix(limit))
    }
    struct NotificationRecord: Sendable {
        var route: String
        var fields: [String: JSONValue]
    }
    private var notificationRecords: [NotificationRecord] = []
    private var notificationState: [Snowflake: [String: JSONValue]] = [:]
    var notificationOperations: [NotificationRecord] { lock.withLock { notificationRecords } }
    #if DEBUG
    private var notificationFailure = false
    var failNextNotificationWrite: Bool {
        get { lock.withLock { notificationFailure } }
        set { lock.withLock { notificationFailure = newValue } }
    }
    private var notificationResponseHook: (@Sendable (GuildSettingsUpdate) async throws -> Void)?
    var beforeNotificationResponse: (@Sendable (GuildSettingsUpdate) async throws -> Void)? {
        get { lock.withLock { notificationResponseHook } }
        set { lock.withLock { notificationResponseHook = newValue } }
    }
    #endif

    func patchNotificationSettings(target: NotificationTarget, patch: NotificationPatch) async throws -> GuildSettingsUpdate {
        let fields = patch.fields(for: target)
        lock.withLock { notificationRecords.append(NotificationRecord(route: "users/@me/guilds/\(target.routeID)/settings", fields: fields)) }
        #if DEBUG
        let fail = lock.withLock { let fail = notificationFailure; notificationFailure = false; return fail }
        if fail { throw DiscordError.http(403, "Mock notification write refused") }
        #endif
        let response = lock.withLock {
            let defaults: [String: JSONValue] = [
                "muted": .bool(false), "message_notifications": .number(3),
                "suppress_everyone": .bool(false), "suppress_roles": .bool(false),
                "mute_config": .null, "channel_overrides": .object([:])
            ]
            var state = GuildSettingsUpdate.mergeObject(notificationState[target.resource] ?? defaults, fields)
            state["guild_id"] = target.resource == 0 ? .null : .string(target.resource.description)
            notificationState[target.resource] = state
            return GuildSettingsUpdate(fields: state)
        }
        var echoFields = fields
        echoFields["guild_id"] = target.resource == 0 ? .null : .string(target.resource.description)
        emit("USER_GUILD_SETTINGS_UPDATE", GuildSettingsUpdate(fields: echoFields))
        #if DEBUG
        if let beforeNotificationResponse { try await beforeNotificationResponse(response) }
        #endif
        return response
    }

    func settingsProto() async throws -> String? { nil }
}

/// Emits READY for the mock data set, then occasional typing, plus the
/// events that echo your own writes (send, edit, delete, react).
final class MockGateway: GatewayConnection, @unchecked Sendable {
    let events: AsyncStream<GatewayEvent>
    private let continuation: AsyncStream<GatewayEvent>.Continuation
    private weak var data: MockDiscord?

    init(data: MockDiscord) {
        self.data = data
        (events, continuation) = AsyncStream.makeStream()
        data.echo = { [continuation] dispatch in continuation.yield(.dispatch(dispatch)) }
    }

    func connect() async {
        continuation.yield(.status(.connecting))
        continuation.yield(.status(.connected))
        continuation.yield(.dispatch(GatewayDispatch(name: "MOCK_READY", data: Data())))
        if let data {
            let presence: [String: JSONValue] = ["merged_presences": .object(["friends": .array([
                .object(["user_id": .string(data.users[0].id.description), "status": .string("online")]),
                .object(["user_id": .string(data.users[1].id.description), "status": .string("offline")])])])]
            if let json = try? JSONEncoder().encode(["d": JSONValue.object(presence)]) {
                continuation.yield(.dispatch(GatewayDispatch(name: "READY_SUPPLEMENTAL", data: json)))
            }
        }
        // `-DuocordMockPing <seconds>`: a mention arrives in #image-dump, for
        // notification and badge checks.
        let delay = UserDefaults.standard.integer(forKey: "DuocordMockPing")
        guard delay > 0, let data else { return }
        let author = data.users[4]
        let me = data.me
        Task { [continuation] in
            try? await Task.sleep(for: .seconds(delay))
            var message = Message(id: Snowflake.at(.now), channelID: MockDiscord.imageChannel, guildID: data.guilds[0].id,
                                  author: author, content: "<@\(me.id)> the book-pose build is up — can you check the fold?",
                                  timestamp: ISO8601DateFormatter().string(from: .now), mentions: [me])
            message.member = Member(user: author, nick: nil, roles: [])
            data.record(message)
            struct Envelope: Encodable { var d: Message }
            if let json = try? JSONEncoder().encode(Envelope(d: message)) {
                continuation.yield(.dispatch(GatewayDispatch(name: "MESSAGE_CREATE", data: json)))
            }
        }
    }

    func disconnect() async { continuation.yield(.status(.disconnected)) }

    /// Answers like Discord: members whose username or nickname starts with the query.
    func requestMembers(guild: Snowflake, query: String, limit: Int) async {
        guard let data else { return }
        let q = query.lowercased()
        let found = data.searchableMembers.filter { member in
            [member.user?.username, member.nick, member.user?.globalName].contains { $0?.lowercased().hasPrefix(q) == true }
        }.prefix(limit)
        struct Chunk: Encodable { var guild_id: Snowflake; var members: [Member]; var chunk_index = 0; var chunk_count = 1 }
        struct Envelope: Encodable { var d: Chunk }
        if let json = try? JSONEncoder().encode(Envelope(d: Chunk(guild_id: guild, members: Array(found)))) {
            continuation.yield(.dispatch(GatewayDispatch(name: "GUILD_MEMBERS_CHUNK", data: json)))
        }
    }

    func subscribe(guild: Snowflake, channel: Snowflake?, ranges: [[Int]]) async {
        guard let data, let guildInfo = data.guilds.first(where: { $0.id == guild }) else { return }
        // A member list in Discord's grouped shape.
        var items: [JSONValue] = []
        let online = data.users.prefix(9), offline = data.users.dropFirst(9)
        // A few server nicknames, so autocomplete matches them too.
        let nicks: [Snowflake: String] = [data.users[1].id: "Bram", data.users[7].id: "Harbs"]
        func member(_ user: User, status: String, role: Snowflake?) -> JSONValue {
            .object(["member": .object([
                "nick": nicks[user.id].map(JSONValue.string) ?? .null,
                "user": .object(["id": .string(user.id.description), "username": .string(user.username),
                                 "global_name": user.globalName.map(JSONValue.string) ?? .null,
                                 "avatar": user.avatar.map(JSONValue.string) ?? .null, "bot": .bool(user.bot ?? false)]),
                "roles": .array(role.map { [.string($0.description)] } ?? []),
                "presence": .object(["status": .string(status)]),
            ])])
        }
        let mods = Snowflake(guild.raw + 900), designers = Snowflake(guild.raw + 901)
        items.append(.object(["group": .object(["id": .string(mods.description), "count": .number(2)])]))
        for user in online.prefix(2) { items.append(member(user, status: "online", role: mods)) }
        items.append(.object(["group": .object(["id": .string(designers.description), "count": .number(3)])]))
        for (i, user) in online.dropFirst(2).prefix(3).enumerated() { items.append(member(user, status: i == 1 ? "idle" : "online", role: designers)) }
        items.append(.object(["group": .object(["id": .string("online"), "count": .number(4)])]))
        for (i, user) in online.dropFirst(5).enumerated() { items.append(member(user, status: i == 0 ? "dnd" : "online", role: nil)) }
        items.append(.object(["group": .object(["id": .string("offline"), "count": .number(Double(offline.count))])]))
        for user in offline { items.append(member(user, status: "offline", role: nil)) }
        let payload: JSONValue = .object([
            "t": .string("GUILD_MEMBER_LIST_UPDATE"),
            "d": .object([
                "guild_id": .string(guildInfo.id.description), "id": .string("everyone"),
                "member_count": .number(Double(data.users.count)), "online_count": .number(9),
                "groups": .array([]),
                "ops": .array([.object(["op": .string("SYNC"), "range": .array([.number(0), .number(99)]), "items": .array(items)])]),
            ]),
        ])
        if let json = try? JSONEncoder().encode(payload) {
            continuation.yield(.dispatch(GatewayDispatch(name: "GUILD_MEMBER_LIST_UPDATE", data: json)))
        }
        if let channel {
            // Someone is typing in the open channel.
            let typing: JSONValue = .object(["d": .object(["channel_id": .string(channel.description), "guild_id": .string(guild.description),
                                                            "user_id": .string(data.users[3].id.description)])])
            if let json = try? JSONEncoder().encode(typing) {
                continuation.yield(.dispatch(GatewayDispatch(name: "TYPING_START", data: json)))
            }
        }
    }
}

nonisolated struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
}

nonisolated enum MockText {
    static let lines = [
        "Folded it to book pose and the channel list lands right on the hinge. Love it.",
        "Has anyone tried the **table-top** layout with a call running?",
        "The outer display feels much less cramped at this text size.",
        "Pushed a new build — scrolling up through history no longer jumps 🎉",
        "`reservedRegions(kind: .division)` gives you the fold frame in view coordinates.",
        "I think the members panel should replace the channel page in book pose, not cover the chat.",
        "> Interactive elements displace away from the fold; continuous content does not.\nThat's the key rule.",
        "lunch?",
        "Here's the reference: https://developer.apple.com/design/human-interface-guidelines",
        "||the ending of the book|| was not what I expected",
        "```swift\nlet fold = view.reservedRegions(kind: .division)\n    .first { $0.isActive }\n```",
        "Sketching three options for the composer:\n- pinned below the fold\n- floating over chat\n- in the side bar",
        "Measured it: 0 pt drift when older pages load. Exactly what we wanted.",
        "*quietly* ships it",
        "## Release notes\nFaster channel switching, better image loading, fewer jumps.",
        "Can someone review the PR before the weekend?",
        "-# posted from the outer display",
        "That photo set from the ridge run is unreal.",
        "brb, coffee ☕",
        "Who's around for the design crit at 4?",
        "The vertical side bar keeps symbol-only items under your thumb. Text items stay horizontal.",
        "Testing a really long message to see how the wrapping behaves across the fold: it should reflow on each page without ever sitting on the hinge itself, and the line length should stay comfortable to read on both displays.",
        "__Reminder:__ meetup moved to Thursday",
        "~~old plan~~ new plan: ship Friday",
        "ok",
        "same",
        "This is the way.",
        "1. fold\n2. unfold\n3. check the draft is still there",
    ]

    static func line(_ rng: inout SeededRandom, users: [User], me: User) -> String {
        var text = lines[rng.int(0...(lines.count - 1))]
        if rng.chance(0.06) { text = "<@\(users[rng.int(0...(users.count - 1))].id)> " + text }
        return text
    }
}
