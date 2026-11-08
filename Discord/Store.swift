import Foundation
import Observation
import os

nonisolated enum Permission {
    static let manageChannels: UInt64 = 1 << 4
    static let addReactions: UInt64 = 1 << 6
    static let manageMessages: UInt64 = 1 << 13
    static let embedLinks: UInt64 = 1 << 14
    static let attachFiles: UInt64 = 1 << 15
    static let sendPolls: UInt64 = 1 << 49
    static let sendPayload: UInt64 = (1 << 12) | embedLinks | attachFiles | mentionEveryone | (1 << 46) | sendPolls
    static let voiceScoped: UInt64 = (1 << 8) | (1 << 9) | (1 << 21) | (1 << 22) | (1 << 23) | (1 << 24) | (1 << 25) | (1 << 32) | (1 << 39)
    static let channelScoped: UInt64 = (1 << 0) | manageChannels | addReactions | voiceScoped | viewChannel | sendMessages
        | manageMessages | sendPayload | readHistory | (1 << 18) | connect | (1 << 29) | (1 << 31)
        | manageThreads | (1 << 35) | (1 << 36) | (1 << 37) | sendInThreads | (1 << 45) | pinMessages
    static let administrator: UInt64 = 1 << 3
    static let viewChannel: UInt64 = 1 << 10
    static let sendMessages: UInt64 = 1 << 11
    static let readHistory: UInt64 = 1 << 16
    static let mentionEveryone: UInt64 = 1 << 17
    static let connect: UInt64 = 1 << 20
    static let sendInThreads: UInt64 = 1 << 38
    static let manageThreads: UInt64 = 1 << 34
    /// Split from Manage Messages; since 2026-02-23 that alone no longer pins.
    static let pinMessages: UInt64 = 1 << 51
    static let all: UInt64 = .max
}

/// One row of the lazily loaded member list.
enum MemberListRow: Hashable, Identifiable {
    case group(id: String, title: String, count: Int)
    case member(Member, PresenceStatus)

    var id: String {
        switch self {
        case .group(let id, _, _): "g-\(id)"
        case .member(let member, _): "m-\(member.userID?.description ?? member.user?.id.description ?? "?")"
        }
    }
}

struct MemberListState {
    var id: String
    /// Slots by Discord's logical index; nil = not loaded / invalidated.
    var slots: [MemberListRow?] = []
    var rows: [MemberListRow] { slots.compactMap { $0 } }
    var memberCount: Int = 0
    var onlineCount: Int = 0
}

/// Everything Duocord knows about the account, updated from READY and
/// gateway dispatches. Main actor; views observe it directly.
@Observable
final class DiscordStore {
    private(set) var me: User?
    private(set) var guilds: [Snowflake: Guild] = [:] {
        didSet {
            derivedRevision &+= 1
            for id in Set(oldValue.keys).union(guilds.keys) where oldValue[id] != guilds[id] { guildFactVersions[id, default: 0] &+= 1 }
        }
    }
    private(set) var guildOrder: [Snowflake] = []
    private(set) var folders: [GuildFolder] = []
    private(set) var channels: [Snowflake: Channel] = [:] {
        didSet { channelIndexValid = false; threadIndexCache = [:]; derivedRevision &+= 1 }
    }
    /// Cached reads must observe invalidation too, including permission changes.
    private var derivedRevision = 0
    @ObservationIgnored private var channelIndexValid = false
    @ObservationIgnored private(set) var channelRevision = 0
    @ObservationIgnored private var channelRevisions: [Snowflake: Int] = [:]
    /// Edits and deletions fence excerpts, including channels with no timeline.
    private(set) var messageContentRevisions: [Snowflake: UInt64] = [:]

    private func changedChannel(_ id: Snowflake) {
        channelRevision += 1
        channelRevisions[id] = channelRevision
    }

    func channelChanged(_ id: Snowflake, since revision: Int) -> Bool {
        channelRevisions[id, default: 0] > revision
    }
    @ObservationIgnored private var channelIndex: [Snowflake: [Snowflake]] = [:]
    @ObservationIgnored private var badgeCache: [Snowflake: (revision: Int, badge: GuildBadge)] = [:]
    @ObservationIgnored private var sectionCache: [Snowflake: (revision: Int, sections: [ChannelSection])] = [:]
    /// Every known thread of a guild by parent, most recent activity first.
    @ObservationIgnored private var threadIndexCache: [Snowflake: [Snowflake: [Channel]]] = [:]

    /// Channel IDs per guild (nil key = DMs), rebuilt lazily after changes.
    private func channelIDs(in guild: Snowflake) -> [Snowflake] {
        if !channelIndexValid {
            var index: [Snowflake: [Snowflake]] = [:]
            for channel in channels.values { index[channel.guildID ?? 0, default: []].append(channel.id) }
            channelIndex = index
            channelIndexValid = true
        }
        return channelIndex[guild] ?? []
    }
    private(set) var privateChannelOrder: [Snowflake] = []
    private(set) var users: [Snowflake: User] = [:]
    private(set) var relationships: [Snowflake: Relationship] = [:]
    private(set) var peopleEpoch = UUID()
    private(set) var privacyRevision: UInt64 = 0
    private(set) var revealedBlockedMessages: Set<Snowflake> = []
    @ObservationIgnored private var relationshipVersions: [Snowflake: UInt64] = [:]
    @ObservationIgnored private(set) var relationshipGeneration: UInt64 = 0
    @ObservationIgnored private var relationshipGenerations: [Snowflake: UInt64] = [:]
    @ObservationIgnored private var personFields: [Snowflake: [String: JSONValue]] = [:]
    @ObservationIgnored private var usernameVersions: [String: UInt64] = [:]
    @ObservationIgnored private var dmVersions: [Snowflake: UInt64] = [:]
    @ObservationIgnored var onPeopleReset: (() -> Void)?
    @ObservationIgnored var onPrivacyChange: (() -> Void)?

    func relationshipVersion(_ id: Snowflake) -> UInt64 { relationshipVersions[id, default: 0] }
    /// Latest relationship-event generation associated with this name.
    func usernameVersion(_ name: String) -> UInt64 { usernameVersions[name, default: 0] }
    func dmVersion(_ id: Snowflake) -> UInt64 { dmVersions[id, default: 0] }
    func isBlocked(_ id: Snowflake) -> Bool { relationships[id]?.type == 2 }
    func hidesBlockedMessage(_ message: Message) -> Bool {
        isBlocked(message.author.id) && !revealedBlockedMessages.contains(message.id)
    }
    func revealBlockedMessage(_ id: Snowflake) {
        guard revealedBlockedMessages.insert(id).inserted else { return }
        privacyChanged()
    }
    private func privacyChanged() {
        privacyRevision &+= 1
        onPrivacyChange?()
    }
    private func resetPeople() {
        messageContentRevisions = [:]
        channelRevision = 0; channelRevisions = [:]
        peopleEpoch = UUID()
        onPeopleReset?()
        relationships = [:]; relationshipVersions = [:]; personFields = [:]; dmVersions = [:]; usernameVersions = [:]
        relationshipGeneration = 0; relationshipGenerations = [:]
        revealedBlockedMessages = []
        privacyChanged()
    }

    /// Merge only present, well-typed profile fields. A user ID alone never
    /// invents a username or borrows a different user's identity.
    func remember(person fields: [String: JSONValue], id: Snowflake, fromGateway: Bool = false) {
        guard let raw = fields["id"],
              let actual = try? JSONDecoder().decode(Snowflake.self, from: JSONEncoder().encode(raw)), actual == id else { return }
        let oldUsername = users[id]?.username
        var base = personFields[id] ?? [:]
        if let known = users[id], let data = try? JSONEncoder().encode(known),
           let encoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            base = base.merging(encoded, uniquingKeysWith: { _, new in new })
        }
        for (key, value) in fields {
            switch (key, value) {
            case ("id", _), ("username", .string), ("global_name", .string), ("global_name", .null),
                 ("avatar", .string), ("avatar", .null), ("discriminator", .string), ("discriminator", .null),
                 ("bot", .bool), ("bot", .null): base[key] = value
            default: break
            }
        }
        personFields[id] = base
        if let data = try? JSONEncoder().encode(base), let user = try? JSONDecoder().decode(User.self, from: data) {
            users[id] = user
            // Associate a gateway-supplied name with its relationship event,
            // even if another path has already populated the user cache.
            // Resolving an old event never creates newer request authority.
            if fromGateway, case .string(let name) = fields["username"], name == user.username,
               let generation = relationshipGenerations[id] {
                for associated in Set([oldUsername, name].compactMap { $0 }) {
                    usernameVersions[associated] = max(usernameVersions[associated, default: 0], generation)
                }
            }
        }
    }
    func remember(person user: User) {
        guard let data = try? JSONEncoder().encode(user),
              let fields = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return }
        remember(person: fields, id: user.id)
    }
    func applyRelationship(_ update: Relationship, remove: Bool = false) {
        let wasBlocked = isBlocked(update.id)
        let oldUsername = users[update.id]?.username
        relationshipVersions[update.id, default: 0] &+= 1
        relationshipGeneration &+= 1
        relationshipGenerations[update.id] = relationshipGeneration
        if let fields = update.userFields { remember(person: fields, id: update.id) }
        for name in Set([oldUsername, users[update.id]?.username].compactMap { $0 }) {
            usernameVersions[name] = max(usernameVersions[name, default: 0], relationshipGeneration)
        }
        if remove { relationships[update.id] = nil }
        else { relationships[update.id] = relationships[update.id]?.merging(update) ?? update }
        if wasBlocked != isBlocked(update.id) {
            // Reblocking hides even previously revealed rows.
            revealedBlockedMessages = []
            privacyChanged()
        }
    }
    func confirmRelationship(_ id: Snowflake, action: RelationshipAction, version: UInt64) {
        guard relationshipVersion(id) == version else { return }
        let update = Relationship(id: id, type: action.resultingType ?? 0)
        applyRelationship(update, remove: action.resultingType == nil)
    }
    func friends(_ filter: FriendsFilter) -> [Relationship] {
        relationships.values.filter { relation in
            switch filter {
            case .all: relation.type == 1
            case .online: relation.type == 1 && presences[relation.id] != nil && presences[relation.id] != .offline && presences[relation.id] != .invisible
            case .pending: relation.type == 3 || relation.type == 4
            case .blocked: relation.type == 2
            }
        }.sorted {
            let a = users[$0.id]?.displayName.lowercased() ?? ""
            let b = users[$1.id]?.displayName.lowercased() ?? ""
            return a == b ? $0.id < $1.id : a < b
        }
    }
    func directMessage(to id: Snowflake) -> Channel? {
        privateChannels.first { channel in
            guard channel.type == .dm else { return false }
            let ids = channel.recipients.map { $0.map(\.id) } ?? channel.recipientIDs ?? []
            return ids.count == 1 && ids.first == id
        }
    }

    private(set) var myMembers: [Snowflake: Member] = [:] {
        didSet {
            derivedRevision &+= 1
            for id in Set(oldValue.keys).union(myMembers.keys) where oldValue[id] != myMembers[id] { memberFactVersions[id, default: 0] &+= 1 }
        }
    }
    @ObservationIgnored private(set) var members: [Snowflake: [Snowflake: Member]] = [:]
    private(set) var readStates: [Snowflake: ReadState] = [:] {
        didSet { derivedRevision &+= 1 }
    }
    /// A fresh READY/cache/reset fences every outstanding read operation.
    private(set) var readEpoch = UUID()
    private(set) var manualUnreadChannels: Set<Snowflake> = []
    @ObservationIgnored var pendingReadChannels: Set<Snowflake> = []
    @ObservationIgnored var pendingUnreadChannels: Set<Snowflake> = []
    @ObservationIgnored var readIntents: [Snowflake: UUID] = [:]
    @ObservationIgnored var onReadReset: (() -> Void)?
    /// Emitted only by accepted boundary-owning branches, after state publication.
    /// Manual unread and mention-only updates deliberately own no alert removal.
    @ObservationIgnored var onAcceptedRead: ((Snowflake, Snowflake) -> Void)?
    @ObservationIgnored private var readEchoes: [Snowflake: [ReadEchoRecord]] = [:]
    @ObservationIgnored private var readWriteSequence = 0
    @ObservationIgnored private var confirmedReadSequences: [Snowflake: Int] = [:]
    @ObservationIgnored private var readServerVersions: [Snowflake: Int] = [:]
    @ObservationIgnored private var readServerFloor: Int?
    @ObservationIgnored private var readVersions: [Snowflake: ReadVersion] = [:]

    /// Reader progress can clear local badges before its debounced server ack.
    @ObservationIgnored private var localReadProgress: [Snowflake: (message: Snowflake, version: Int)] = [:]

    func hasUnconfirmedRead(_ channel: Snowflake) -> Bool { localReadProgress[channel] != nil }

    private func confirmLocalRead(_ channel: Snowflake, through message: Snowflake, version: Int) {
        if let local = localReadProgress[channel], local.message <= message, local.version <= version {
            localReadProgress[channel] = nil
        }
    }

    func readVersion(_ channel: Snowflake) -> ReadVersion { readVersions[channel] ?? ReadVersion() }

    private func resetReadOperations() {
        onReadReset?()
        readEpoch = UUID()
        deletedFactChannels = []; deletedFactGuilds = []
        guildFactVersions = [:]; memberFactVersions = [:]
        readEchoes = [:]; readServerVersions = [:]; readServerFloor = nil
        readWriteSequence = 0; confirmedReadSequences = [:]; localReadProgress = [:]
        manualUnreadChannels = []; pendingReadChannels = []; pendingUnreadChannels = []; readIntents = [:]; readVersions = [:]
    }

    func resumeAutomaticReading(_ channel: Snowflake) {
        manualUnreadChannels.remove(channel)
    }

    func registerReadEcho(_ read: ReadAcknowledgement, intent: UUID, releasesHold: Bool) {
        var entries = readEchoes[read.channel] ?? []
        readWriteSequence += 1
        entries.append(ReadEchoRecord(read: read, intent: intent, sequence: readWriteSequence,
                                      releasesHold: releasesHold, capturedVersion: readVersion(read.channel)))
        readEchoes[read.channel] = Array(entries.suffix(32))
    }

    func readWasEchoed(_ channel: Snowflake, intent: UUID) -> Bool {
        readEchoes[channel]?.last(where: { $0.intent == intent && !$0.superseded })?.seen == true
    }

    @discardableResult
    func applyRead(_ read: ReadAcknowledgement, version: ReadVersion, intent: UUID, preservingMentions: Bool = false) -> Bool {
        guard let record = readEchoes[read.channel]?.last(where: { $0.intent == intent }),
              !record.superseded,
              record.sequence >= confirmedReadSequences[read.channel, default: 0] else { return false }
        confirmedReadSequences[read.channel] = record.sequence
        var state = readStates[read.channel] ?? ReadState(id: read.channel, lastMessageID: nil, mentionCount: 0)
        let current = readVersion(read.channel)
        if current.boundary == version.boundary {
            state.lastMessageID = read.manual ? read.message : max(read.message, state.lastMessageID ?? 0)
            if read.manual { manualUnreadChannels.insert(read.channel) }
            else { manualUnreadChannels.remove(read.channel) }
        }
        if current.boundary == version.boundary || state.lastMessageID == read.message {
            if read.manual, let count = read.mentionCount {
                if let merged = manualMentionCount(count, captured: version, current: current) { state.mentionCount = merged }
            } else if current.mentions == version.mentions {
                if let count = read.mentionCount { state.mentionCount = count }
                // Only an alert already partial when queued needs to keep an
                // unknown remaining count. Mention versions fence new arrivals.
                else if !read.manual, !preservingMentions { state.mentionCount = 0 }
            }
        }
        readStates[read.channel] = state
        if read.manual, current.boundary == version.boundary { localReadProgress[read.channel] = nil }
        else if !read.manual { confirmLocalRead(read.channel, through: read.message, version: version.boundary) }
        if !read.manual, current.boundary == version.boundary, let boundary = state.lastMessageID {
            onAcceptedRead?(read.channel, boundary)
        }
        return true
    }

    private func manualMentionCount(_ count: Int, captured: ReadVersion, current: ReadVersion) -> Int? {
        let arrivals = current.mentionArrivals - captured.mentionArrivals
        // Only arrivals may be merged. A partial count update or later read
        // is independent authority and keeps its value.
        guard arrivals >= 0, current.mentions - captured.mentions == arrivals else { return nil }
        return max(0, count) > Int.max - arrivals ? Int.max : max(0, count) + arrivals
    }

    private func applyReadEcho(_ ack: MessageAck) {
        guard ack.ackType == nil || ack.ackType == 0 else { return }
        if let version = ack.version {
            if let previous = readServerVersions[ack.channelID] ?? readServerFloor, version <= previous { return }
            readServerVersions[ack.channelID] = version
        }
        var releasesHold = false
        var localEcho: ReadEchoRecord?
        if let id = ack.messageID, var entries = readEchoes[ack.channelID],
           let index = entries.lastIndex(where: { $0.read.message == id && $0.read.manual == (ack.manual == true) }) {
            let known = entries[index]
            if known.superseded {
                // The channel version check already rejected older versions.
                // A new version may reuse this boundary; a versionless old echo may not.
                guard ack.version != nil else { return }
            } else {
                entries[index].seen = true
                entries[index].version = ack.version
                readEchoes[ack.channelID] = entries
                // Without correlation IDs, repeated versionless fingerprints
                // conservatively belong to the recorded local operation.
                if known.sequence < confirmedReadSequences[ack.channelID, default: 0],
                   !known.seen || ack.version == nil || (ack.version ?? 0) <= (known.version ?? 0) { return }
                if !known.seen || ack.version == nil || known.version == nil { localEcho = known }
                releasesHold = known.releasesHold
                confirmedReadSequences[ack.channelID] = max(known.sequence, confirmedReadSequences[ack.channelID, default: 0])
            }
        }
        // Distinct, accepted versioned authority from another client supersedes
        // a local hold. Known obsolete local fingerprints were rejected above.
        if ack.version != nil, ack.messageID != nil, ack.manual != true, localEcho == nil { releasesHold = true }
        var state = readStates[ack.channelID] ?? ReadState(id: ack.channelID, lastMessageID: nil, mentionCount: 0)
        var version = readVersion(ack.channelID)
        let previousBoundaryVersion = version.boundary
        // An automatic/late echo cannot undo a deliberate unread hold. Manual
        // gateway updates can lower boundaries; omitted fields own nothing.
        let held = manualUnreadChannels.contains(ack.channelID) && !releasesHold
        if let id = ack.messageID, ack.manual == true || !held {
            if localEcho == nil, var entries = readEchoes[ack.channelID] {
                // Accepted external boundary authority fences both completed
                // and in-flight local writes registered before this event.
                for index in entries.indices { entries[index].superseded = true }
                readEchoes[ack.channelID] = entries
            }
            if ack.manual == true {
                state.lastMessageID = id
                manualUnreadChannels.insert(ack.channelID)
            } else {
                state.lastMessageID = max(id, state.lastMessageID ?? 0)
                if releasesHold { manualUnreadChannels.remove(ack.channelID) }
            }
            if ack.manual == true { localReadProgress[ack.channelID] = nil }
            else {
                confirmLocalRead(ack.channelID, through: id,
                                 version: localEcho?.capturedVersion.boundary ?? previousBoundaryVersion)
            }
            version.boundary += 1
        }
        if let count = ack.mentionCount, !held || ack.manual == true {
            // A captured ack must not consume a mention received beyond it.
            if ack.manual == true || count != 0 || ack.messageID == nil || ack.messageID.map({ (channels[ack.channelID]?.lastMessageID ?? 0) <= $0 }) == true {
                if ack.manual == true, let localEcho, localEcho.read.mentionCount == count {
                    if let merged = manualMentionCount(count, captured: localEcho.capturedVersion, current: version) {
                        state.mentionCount = merged
                        version.mentions += 1
                    }
                } else {
                    state.mentionCount = max(0, count)
                    version.mentions += 1
                }
            }
        }
        readVersions[ack.channelID] = version
        readStates[ack.channelID] = state
        if version.boundary != previousBoundaryVersion, ack.manual != true, let boundary = state.lastMessageID {
            onAcceptedRead?(ack.channelID, boundary)
        }
    }

    private(set) var guildSettings: [Snowflake: UserGuildSettings] = [:] {
        didSet { derivedRevision &+= 1; scheduleMuteExpiry() }
    }
    private(set) var voiceStates: [Snowflake: [Snowflake: VoiceState]] = [:]
    private(set) var typing: [Snowflake: [Snowflake: Date]] = [:]
    private(set) var memberLists: [Snowflake: MemberListState] = [:]
    private(set) var presences: [Snowflake: PresenceStatus] = [:]
    private(set) var isReady = false
    /// Threads the current user is a member of (private threads need membership to post).
    private(set) var joinedThreads: Set<Snowflake> = [] {
        didSet { derivedRevision &+= 1 }
    }
    private(set) var knownAbsentThreadMemberships: Set<Snowflake> = []
    /// Changes when a member search (op 8) answers, since `members` itself isn't observed.
    private(set) var memberSearchRevision = 0

    @ObservationIgnored private let log = Logger(subsystem: "com.saphid.duocord.native", category: "store")
    /// The channel on screen. Its new messages only skip the mention count
    /// while the reader is actually at its newest messages with the app active.
    @ObservationIgnored var visibleChannel: Snowflake?
    @ObservationIgnored var visibleIsLive = false
    @ObservationIgnored var onMessageCreate: ((Message) -> Void)?

    // MARK: Lookups

    struct FactSnapshot {
        let epoch: UUID
        let channelRevision: Int
        let guilds: [Snowflake: UInt64]
        let members: [Snowflake: UInt64]
    }
    @ObservationIgnored private var guildFactVersions: [Snowflake: UInt64] = [:]
    @ObservationIgnored private var memberFactVersions: [Snowflake: UInt64] = [:]
    @ObservationIgnored private var deletedFactChannels: Set<Snowflake> = []
    @ObservationIgnored private var deletedFactGuilds: Set<Snowflake> = []

    /// Capture before the first read, including facts whose IDs that read may discover.
    func factSnapshot() -> FactSnapshot {
        FactSnapshot(epoch: readEpoch, channelRevision: channelRevision, guilds: guildFactVersions, members: memberFactVersions)
    }
    func canRefreshChannel(_ id: Snowflake, snapshot: FactSnapshot) -> Bool {
        readEpoch == snapshot.epoch && !deletedFactChannels.contains(id)
            && !channelChanged(id, since: snapshot.channelRevision)
    }
    @discardableResult
    func commitFactChannel(_ channel: Channel, snapshot: FactSnapshot) -> Bool {
        guard canRefreshChannel(channel.id, snapshot: snapshot),
              channel.guildID.map({ !deletedFactGuilds.contains($0) }) ?? channel.type.isPrivate else { return false }
        upsert(channel: channel)
        return true
    }
    @discardableResult
    func commitFactGuild(_ guild: Guild, snapshot: FactSnapshot) -> Bool {
        guard readEpoch == snapshot.epoch, !deletedFactGuilds.contains(guild.id),
              guildFactVersions[guild.id, default: 0] == snapshot.guilds[guild.id, default: 0] else { return false }
        // A guild read never replaces channel, role or member event state.
        if var current = guilds[guild.id] { current.ownerID = guild.ownerID; current.unavailable = guild.unavailable; guilds[guild.id] = current }
        else { var minimal = Guild(id: guild.id, name: guild.name); minimal.ownerID = guild.ownerID; minimal.unavailable = guild.unavailable; guilds[guild.id] = minimal }
        return true
    }
    @discardableResult
    func commitFactRoles(_ roles: [Role], guild: Snowflake, snapshot: FactSnapshot) -> Bool {
        guard readEpoch == snapshot.epoch, !deletedFactGuilds.contains(guild),
              guildFactVersions[guild, default: 0] == snapshot.guilds[guild, default: 0], guilds[guild] != nil else { return false }
        guilds[guild]?.roles = roles
        return true
    }
    @discardableResult
    func commitFactMember(_ member: Member, guild: Snowflake, snapshot: FactSnapshot) -> Bool {
        guard readEpoch == snapshot.epoch, !deletedFactGuilds.contains(guild), member.userID == me?.id,
              memberFactVersions[guild, default: 0] == snapshot.members[guild, default: 0] else { return false }
        myMembers[guild] = member
        return true
    }
    @discardableResult
    func commitFactMembership(_ member: ThreadMemberRef, thread: Snowflake, snapshot: FactSnapshot) -> Bool {
        guard canRefreshChannel(thread, snapshot: snapshot), channels[thread] != nil else { return false }
        changedChannel(thread)
        channels[thread]?.member = member
        joinedThreads.insert(thread); knownAbsentThreadMemberships.remove(thread)
        return true
    }

    @discardableResult
    func commitFactAbsentMembership(thread: Snowflake, snapshot: FactSnapshot) -> Bool {
        guard canRefreshChannel(thread, snapshot: snapshot), channels[thread] != nil else { return false }
        setThreadMembership(thread, joined: false)
        return true
    }

    private func rememberGatewayMember(_ member: Member, guild: Snowflake) {
        guard let id = member.userID ?? member.user?.id else { return }
        if id == me?.id {
            memberFactVersions[guild, default: 0] &+= 1
            var copy = member
            copy.userID = id
            if let known = myMembers[guild] {
                if !copy.rolesKnown { copy.roles = known.roles; copy.rolesKnown = known.rolesKnown }
                if copy.communicationDisabledUntil == nil { copy.communicationDisabledUntil = known.communicationDisabledUntil }
            }
            myMembers[guild] = copy
        } else { members[guild, default: [:]][id] = member }
    }

    func channel(_ id: Snowflake) -> Channel? { channels[id] }

    func member(_ user: Snowflake, in guild: Snowflake?) -> Member? {
        guard let guild else { return nil }
        if user == me?.id { return myMembers[guild] }
        return members[guild]?[user]
    }

    func displayName(for user: User, in guild: Snowflake?) -> String {
        member(user.id, in: guild)?.nick?.nonEmpty ?? user.displayName
    }

    func role(_ id: Snowflake, in guild: Snowflake?) -> Role? {
        guild.flatMap { guilds[$0]?.roles.first { $0.id == id } }
    }

    /// The colour of a member's highest coloured role, if any.
    func roleColor(for user: Snowflake, in guild: Snowflake?) -> Int? {
        guard let guild, let roles = member(user, in: guild)?.roles, let all = guilds[guild]?.roles else { return nil }
        return all.filter { roles.contains($0.id) && $0.color != 0 }.max { $0.position < $1.position }?.color
    }

    func roleColor(for member: Member, in guild: Snowflake) -> Int? {
        guard let all = guilds[guild]?.roles else { return nil }
        return all.filter { member.roles.contains($0.id) && $0.color != 0 }.max { $0.position < $1.position }?.color
    }

    func channelName(_ channel: Channel) -> String {
        if channel.type.isPrivate { return dmName(channel) }
        return channel.name ?? "unknown"
    }

    func dmName(_ channel: Channel) -> String {
        if let name = channel.name?.nonEmpty { return name }
        let names = recipients(of: channel).map(\.displayName)
        return names.isEmpty ? "Direct Message" : names.joined(separator: ", ")
    }

    func recipients(of channel: Channel) -> [User] {
        if let recipients = channel.recipients, !recipients.isEmpty { return recipients }
        return (channel.recipientIDs ?? []).compactMap { users[$0] }
    }

    // MARK: Sidebar structure

    struct ChannelSection: Identifiable {
        var category: Channel?
        var channels: [Channel]
        var id: Snowflake { category?.id ?? 0 }
    }

    /// Visible channels grouped under categories in Discord's order.
    func sections(for guildID: Snowflake) -> [ChannelSection] {
        _ = channels // observation dependency
        if let cached = sectionCache[guildID], cached.revision == derivedRevision { return cached.sections }
        let result = computeSections(for: guildID)
        sectionCache[guildID] = (derivedRevision, result)
        return result
    }

    private func computeSections(for guildID: Snowflake) -> [ChannelSection] {
        let all = channelIDs(in: guildID).compactMap { channels[$0] }.filter { !$0.type.isThread }
        let visible = all.filter { canView($0) }
        let sorted: (Channel, Channel) -> Bool = { a, b in
            let av = a.type.isVoice ? 1 : 0, bv = b.type.isVoice ? 1 : 0
            if av != bv { return av < bv }
            if (a.position ?? 0) != (b.position ?? 0) { return (a.position ?? 0) < (b.position ?? 0) }
            return a.id < b.id
        }
        let categories = all.filter { $0.type == .category }.sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
        var result: [ChannelSection] = []
        // Missing-parent threads still explain their activity in the sidebar.
        // Only metadata is shown until opening resolves the parent's permissions.
        let unresolved = channelIDs(in: guildID).compactMap { channels[$0] }
            .filter { canShowUnresolvedThreadMetadata($0) }.sorted(by: Self.threadOrder)
        let uncategorized = visible.filter { $0.parentID == nil && $0.type != .category }.sorted(by: sorted) + unresolved
        if !uncategorized.isEmpty { result.append(ChannelSection(category: nil, channels: uncategorized)) }
        for category in categories {
            let children = visible.filter { $0.parentID == category.id && $0.type != .category }.sorted(by: sorted)
            if !children.isEmpty { result.append(ChannelSection(category: category, channels: children)) }
        }
        return result
    }

    /// Active threads under a channel the user can see.
    func threads(in parent: Snowflake) -> [Channel] {
        _ = channels // observation dependency
        guard let guild = channels[parent]?.guildID else { return [] }
        return (threadIndex(in: guild)[parent] ?? []).filter {
            $0.threadMetadata?.archived != true && contentAccess(to: $0).permitsContent
        }
    }

    /// Every known thread under a parent, archived ones and forum posts
    /// included, whether or not the sidebar lists it. Callers check access.
    func knownThreads(in parent: Snowflake) -> [Channel] {
        _ = channels // observation dependency
        guard let guild = channels[parent]?.guildID else { return [] }
        return threadIndex(in: guild)[parent] ?? []
    }

    private func threadIndex(in guild: Snowflake) -> [Snowflake: [Channel]] {
        if let cached = threadIndexCache[guild] { return cached }
        var byParent: [Snowflake: [Channel]] = [:]
        for id in channelIDs(in: guild) {
            guard let channel = channels[id], channel.type.isThread, let parent = channel.parentID else { continue }
            byParent[parent, default: []].append(channel)
        }
        for parent in Array(byParent.keys) { byParent[parent]?.sort(by: Self.threadOrder) }
        threadIndexCache[guild] = byParent
        return byParent
    }

    /// Most recent activity first; equal activity puts the newer thread first.
    nonisolated static func threadOrder(_ a: Channel, _ b: Channel) -> Bool {
        let x = a.lastMessageID ?? a.id, y = b.lastMessageID ?? b.id
        return x != y ? x > y : a.id > b.id
    }

    // MARK: Sidebar channel list

    /// Unread activity and mentions rolled up from a parent channel's threads.
    struct ThreadRollup: Equatable {
        var unreadThreads = 0
        var mentions = 0
        var mentionThreads = 0
        var unread: Bool { unreadThreads > 0 }
    }

    /// One channel row of the sidebar, the thread rows drawn under it and
    /// their rollup. The row itself draws only its own state; each thread's
    /// activity stays on that thread's row.
    struct ChannelListEntry: Identifiable {
        var channel: Channel
        var threads: [Channel]
        var hiddenThreads = 0
        var rollup = ThreadRollup()
        var showsVoice = false
        /// Threads the sidebar can list under this channel (its disclosure shows when > 0).
        var threadCount = 0
        /// The channel's own thread disclosure is collapsed.
        var threadsCollapsed = false
        /// A collapsed category's chevron owns visibility, so its channels offer no thread disclosure.
        var showsThreadDisclosure = false
        var id: Snowflake { channel.id }
    }

    struct ChannelListSection: Identifiable {
        var category: Channel?
        var collapsed: Bool
        var entries: [ChannelListEntry]
        var id: Snowflake { category?.id ?? 0 }
    }

    static let sidebarThreadLimit = 5

    /// Unread activity the user hasn't muted, as rows draw it.
    func showsUnread(_ channel: Channel) -> Bool { isUnread(channel) && !isMuted(channel) }

    private func needsAttention(_ thread: Channel) -> Bool { showsUnread(thread) || mentionCount(thread.id) > 0 }

    /// Threads the sidebar can list under a parent: every viewable active
    /// thread, plus archived ones still carrying unread activity or mentions,
    /// and the open one. Forum posts are threads of their forum.
    func sidebarThreads(in parent: Snowflake, selected: Snowflake? = nil) -> [Channel] {
        _ = channels; _ = readStates // observation dependencies
        guard let guild = channels[parent]?.guildID else { return [] }
        return (threadIndex(in: guild)[parent] ?? []).filter { thread in
            guard canView(thread) else { return false }
            return thread.threadMetadata?.archived != true || thread.id == selected || needsAttention(thread)
        }
    }

    /// What a parent's threads add to the server badge. Each thread belongs
    /// to one parent, so the badge sums parents without counting twice.
    func threadRollup(for parent: Snowflake) -> ThreadRollup { rollup(of: sidebarThreads(in: parent)) }

    private func rollup(of threads: [Channel]) -> ThreadRollup {
        var rollup = ThreadRollup()
        for thread in threads {
            if showsUnread(thread) { rollup.unreadThreads += 1 }
            let count = mentionCount(thread.id)
            if count > 0 { rollup.mentions += count; rollup.mentionThreads += 1 }
        }
        return rollup
    }

    /// The guild's sidebar rows, as ChannelList draws them. Beyond the most
    /// recent few, a parent lists only threads needing attention until
    /// expanded; a collapsed category keeps only what needs attention or is open.
    /// A parent in `threadsCollapsed` hides every thread row under it, unread,
    /// mentioned and open ones included: the user asked to hide them. The
    /// parent row still draws only its own state; its disclosure says what it hides.
    func channelList(for guildID: Snowflake, collapsed: Set<Snowflake> = [], expanded: Set<Snowflake> = [],
                     threadsCollapsed: Set<Snowflake> = [], selected: Snowflake? = nil) -> [ChannelListSection] {
        sections(for: guildID).map { section in
            let isCollapsed = section.category.map { collapsed.contains($0.id) } ?? false
            let entries = section.channels.compactMap { channel -> ChannelListEntry? in
                let threads = sidebarThreads(in: channel.id, selected: selected)
                let rollup = rollup(of: threads)
                let attention = Set(threads.filter { $0.id == selected || needsAttention($0) }.map(\.id))
                if isCollapsed {
                    guard isUnread(channel) || mentionCount(channel.id) > 0 || selected == channel.id || !attention.isEmpty else { return nil }
                    return ChannelListEntry(channel: channel, threads: threads.filter { attention.contains($0.id) }, rollup: rollup)
                }
                let shown: [Channel]
                let folded = threadsCollapsed.contains(channel.id)
                if folded {
                    shown = []
                } else if expanded.contains(channel.id) || threads.count <= Self.sidebarThreadLimit {
                    shown = threads
                } else {
                    let recent = Set(threads.prefix(Self.sidebarThreadLimit).map(\.id))
                    shown = threads.filter { recent.contains($0.id) || attention.contains($0.id) }
                }
                return ChannelListEntry(channel: channel, threads: shown, hiddenThreads: threads.count - shown.count,
                                        rollup: rollup, showsVoice: channel.type.isVoice, threadCount: threads.count,
                                        threadsCollapsed: folded, showsThreadDisclosure: !threads.isEmpty)
            }
            return ChannelListSection(category: section.category, collapsed: isCollapsed, entries: entries)
        }
    }

    enum SidebarItem: Identifiable, Hashable {
        case guild(Snowflake)
        case folder(GuildFolder)
        var id: String {
            switch self {
            case .guild(let id): "g\(id)"
            case .folder(let folder): "f\(folder.id ?? 0)-\(folder.guildIDs.first?.description ?? "")"
            }
        }
    }

    /// Server rail items: folders from settings, then any guild not in one.
    var sidebarItems: [SidebarItem] {
        var placed = Set<Snowflake>()
        var items: [SidebarItem] = []
        for folder in folders {
            let ids = folder.guildIDs.filter { guilds[$0] != nil }
            guard !ids.isEmpty else { continue }
            placed.formUnion(ids)
            if folder.id == nil || ids.count == 1 {
                items += ids.map { .guild($0) }
            } else {
                var copy = folder
                copy.guildIDs = ids
                items.append(.folder(copy))
            }
        }
        // Newly joined guilds appear on top, as in Discord.
        let rest = guildOrder.filter { !placed.contains($0) && guilds[$0] != nil }
        return rest.reversed().map { .guild($0) } + items
    }

    var privateChannels: [Channel] {
        privateChannelOrder.compactMap { channels[$0] }
    }

    // MARK: Permissions

    /// Compatibility bitset. Unknown facts map to zero; callers needing a
    /// reason or refresh decision must use permissionResolution instead.
    func permissions(in channel: Channel) -> UInt64 {
        permissionResolution(in: channel).permissions ?? 0
    }

    func capabilityContext(in channel: Channel, now: Date = Date(),
                           slowmodeHistory: SlowmodeHistory = .unknown,
                           messageAuthorID: Snowflake? = nil) -> CapabilityContext {
        let membership: ThreadMembership = joinedThreads.contains(channel.id) ? .joined
            : knownAbsentThreadMemberships.contains(channel.id) || channel.type != .privateThread ? .notJoined : .unknown
        return CapabilityContext(channel: channel, account: me,
                                 guild: channel.guildID.flatMap { guilds[$0] },
                                 member: channel.guildID.flatMap { myMembers[$0] },
                                 parent: channel.parentID.flatMap { channels[$0] }, membership: membership,
                                 messageAuthorID: messageAuthorID, accountKind: me?.bot == true ? .bot : .human,
                                 slowmodeHistory: slowmodeHistory, now: now)
    }

    func permissionResolution(in channel: Channel, now: Date = Date()) -> PermissionResolution {
        CapabilityResolver.permissions(capabilityContext(in: channel, now: now))
    }

    func capability(_ operation: DiscordOperation, in channel: Channel, now: Date = Date(),
                    slowmodeHistory: SlowmodeHistory = .unknown,
                    messageAuthorID: Snowflake? = nil) -> CapabilityDecision {
        if contentAccess(to: channel) == .ageRestricted {
            return .denied(.contentRestricted, .contentSafety)
        }
        return operation.evaluate(capabilityContext(in: channel, now: now, slowmodeHistory: slowmodeHistory,
                                            messageAuthorID: messageAuthorID))
    }

    func canView(_ channel: Channel) -> Bool {
        contentAccess(to: channel).permitsContent && capability(.viewChannel, in: channel).isAllowed
    }

    func isUnresolvedThread(_ channel: Channel) -> Bool {
        channel.type.isThread && channel.parentID.flatMap { channels[$0] } == nil
    }

    /// Metadata already received from Discord may explain unresolved activity
    /// in the sidebar. This coarse guild-role check grants no history access;
    /// canView and operation capabilities still require the real parent.
    private func canShowUnresolvedThreadMetadata(_ channel: Channel) -> Bool {
        guard isUnresolvedThread(channel) else { return false }
        if channel.type == .privateThread, channel.ownerID != me?.id, !joinedThreads.contains(channel.id) { return false }
        var metadata = channel
        metadata.type = .text
        metadata.permissionOverwrites = []
        return capability(.viewChannel, in: metadata).isAllowed
    }

    /// @everyone, @here and every role (not just mentionable ones) ping.
    func canMentionEveryone(in channel: Channel) -> Bool {
        channel.guildID != nil && permissions(in: channel) & Permission.mentionEveryone != 0
    }

    /// Roles an @mention here would ping, highest first (@everyone itself excluded).
    func mentionableRoles(in channel: Channel) -> [Role] {
        guard let guild = channel.guildID, let roles = guilds[guild]?.roles else { return [] }
        let all = canMentionEveryone(in: channel)
        return roles.filter { $0.id != guild && ($0.mentionable || all) }.sorted { $0.position > $1.position }
    }

    /// An affordance adapter, not dispatch authorization. Unknown slowmode
    /// facts alone keep drafting available; the full decision retains unknown.
    func canSend(in channel: Channel) -> Bool {
        let decision = capability(.send(MessagePayloadFeatures()), in: channel)
        return decision.isAllowed || (decision.state == .unknown && !decision.reasons.isEmpty
            && decision.reasons.allSatisfy { $0 == .missing(.slowmodeConfiguration) || $0 == .missing(.slowmodeHistory) })
    }

    func canPin(in channel: Channel) -> Bool {
        let decision = capability(.pinMessage, in: channel)
        return decision.isAllowed || (decision.state == .unknown && !decision.reasons.isEmpty
            && decision.reasons.allSatisfy { if case .accountValidationRequired = $0 { true } else { false } })
    }

    // MARK: Pins

    /// Per channel, bumped by CHANNEL_PINS_UPDATE: an open Pins view reloads.
    private(set) var pinsRevisions: [Snowflake: Int] = [:]

    func pinsRevision(for channel: Snowflake) -> Int { pinsRevisions[channel, default: 0] }

    /// A full replacement starts a new store epoch; old revisions mean nothing in it.
    private func resetPins() { pinsRevisions = [:] }

    private func applyPinsUpdate(_ update: ChannelPinsUpdate) {
        // Explicit null: no pins remain. Omitted: unknown, keep what is known.
        if update.timestampProvided, var channel = channels[update.channelID], channel.lastPinTimestamp != update.lastPinTimestamp {
            channel.lastPinTimestamp = update.lastPinTimestamp
            channels[update.channelID] = channel
        }
        pinsRevisions[update.channelID, default: 0] &+= 1
    }

    // MARK: Unread and mentions

    // One deadline for every mute, rather than timers attached to rows.
    @ObservationIgnored private var muteExpiryTask: Task<Void, Never>?
    @ObservationIgnored private let notificationClock: () -> Date
    private(set) var notificationTimeRevision = 0
    @ObservationIgnored private var settingsVersions: [Snowflake: [String: UInt64]] = [:]
    @ObservationIgnored private var settingsVersion: UInt64 = 0
    @ObservationIgnored private var settingsSnapshotVersion: UInt64 = 0

    init(notificationClock: @escaping () -> Date = { .now }) {
        self.notificationClock = notificationClock
    }

    var notificationNow: Date { notificationClock() }

    func refreshMuteExpirations() {
        notificationTimeRevision &+= 1
        derivedRevision &+= 1
        scheduleMuteExpiry()
    }

    private func scheduleMuteExpiry() {
        muteExpiryTask?.cancel()
        let now = notificationClock()
        var deadlines = guildSettings.values.flatMap { settings -> [Date] in
            var ends = settings.channelOverrides.filter(\.muted).compactMap { $0.muteConfig?.endTime.flatMap(DiscordDate.parse) }
            if settings.muted, let end = settings.muteConfig?.endTime.flatMap(DiscordDate.parse) { ends.append(end) }
            return ends
        }
        // Thread mutes live on the current user's thread members.
        for id in joinedThreads {
            if let member = channels[id]?.member, member.muted == true,
               let end = member.muteConfig?.endTime.flatMap(DiscordDate.parse) { deadlines.append(end) }
        }
        guard let next = deadlines.filter({ $0 > now }).min() else { muteExpiryTask = nil; return }
        let delay = next.timeIntervalSince(now)
        muteExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.refreshMuteExpirations()
        }
    }

    func isDirectlyMuted(_ target: NotificationTarget) -> Bool {
        _ = notificationTimeRevision
        if let id = target.channelID, channels[id]?.type.isThread == true {
            guard let member = threadMember(id) else { return false }
            return member.muted == true && isActiveMute(member.muteConfig)
        }
        let settings = guildSettings[target.resource]
        if let id = target.channelID {
            guard let entry = settings?.channelOverrides.first(where: { $0.channelID == id }) else { return false }
            return entry.muted && isActiveMute(entry.muteConfig)
        }
        return settings?.muted == true && isActiveMute(settings?.muteConfig)
    }

    func isMuted(_ channel: Channel) -> Bool {
        var current: Snowflake? = channel.id
        var visited = Set<Snowflake>()
        while let id = current, visited.insert(id).inserted {
            if isDirectlyMuted(.channel(guild: channel.guildID, channel: id)) { return true }
            current = channels[id]?.parentID
        }
        return false
    }

    func isMuted(guild: Snowflake) -> Bool { isDirectlyMuted(.guild(guild)) }

    private func isActiveMute(_ config: MuteConfig?) -> Bool {
        guard let end = config?.endTime.flatMap(DiscordDate.parse) else { return true }
        return end > notificationClock()
    }

    func notificationLevel(_ target: NotificationTarget) -> NotificationLevel {
        if let id = target.channelID, channels[id]?.type.isThread == true {
            return ThreadMemberFlags.level(threadMember(id)?.flags)
        }
        let settings = guildSettings[target.resource]
        let raw: Int
        if let id = target.channelID { raw = settings?.channelOverrides.first { $0.channelID == id }?.messageNotifications ?? 3 }
        else { raw = settings?.messageNotifications ?? 3 }
        return NotificationLevel(rawValue: raw) ?? .inherit
    }

    func effectiveNotificationLevel(_ target: NotificationTarget) -> (level: NotificationLevel, source: String) {
        var current = target.channelID
        var visited = Set<Snowflake>()
        while let id = current, visited.insert(id).inserted {
            let level = notificationLevel(.channel(guild: target.resource == 0 ? nil : target.resource, channel: id))
            if level != .inherit { return (level, channels[id].map { $0.type.isPrivate ? dmName($0) : $0.name ?? "Channel" } ?? "Channel") }
            current = channels[id]?.parentID
        }
        let guildLevel = notificationLevel(.guild(target.resource))
        if guildLevel != .inherit { return (guildLevel, target.resource == 0 ? "Private messages" : "Server settings") }
        return (NotificationLevel(rawValue: guilds[target.resource]?.defaultMessageNotifications ?? (target.resource == 0 ? 0 : 1)) ?? .mentions,
                target.resource == 0 ? "Private message default" : "Server default")
    }

    func notificationVersions(for resource: Snowflake) -> [String: UInt64] {
        var versions = settingsVersions[resource] ?? [:]
        versions["$snapshot"] = settingsSnapshotVersion
        return versions
    }

    /// HTTP may contain a full snapshot taken before a newer gateway update.
    /// Apply only requested fields, and only if that field has not changed
    /// authoritatively since the request began. Gateway partials merge freely.
    func applyNotificationSettings(_ update: GuildSettingsUpdate, resource: Snowflake,
                                   requested: Set<String>? = nil, versions: [String: UInt64]? = nil) throws {
        if let versions, versions["$snapshot"] != settingsSnapshotVersion { return }
        var base = guildSettings[resource].flatMap { try? JSONEncoder().encode($0) }
            .flatMap { try? JSONDecoder().decode(GuildSettingsUpdate.self, from: $0) }?.fields ?? [:]
        base["guild_id"] = resource == 0 ? .null : .string(resource.description)
        var changed = [String]()
        for (path, value) in update.leaves {
            if let requested, !requested.contains(path) { continue }
            if let versions, (settingsVersions[resource]?[path] ?? 0) != (versions[path] ?? 0) { continue }
            base = GuildSettingsUpdate.applying(value, at: path, to: base)
            changed.append(path)
        }
        let merged = try JSONDecoder().decode(UserGuildSettings.self, from: JSONEncoder().encode(base))
        guildSettings[resource] = merged
        for path in changed {
            settingsVersion &+= 1
            settingsVersions[resource, default: [:]][path] = settingsVersion
        }
    }

    func isUnread(_ channel: Channel) -> Bool {
        guard channel.type.isTextLike || channel.type.isForumLike, let last = channel.lastMessageID else { return false }
        guard let boundary = readBoundary(channel) else { return false }
        return last > boundary
    }

    /// The last read message. Without a saved read state, a joined thread is
    /// read up to when the user joined it (Discord's own guess), or its
    /// creation if the join time is unknown. Unjoined threads and other
    /// channels without a read state stay read, as before.
    func readBoundary(_ channel: Channel) -> Snowflake? {
        if let state = readStates[channel.id] { return state.lastMessageID ?? 0 }
        guard channel.type.isThread, joinedThreads.contains(channel.id) else { return nil }
        if let joined = channel.member?.joinTimestamp.flatMap(DiscordDate.parse) { return Snowflake.at(joined) }
        return channel.id
    }

    func mentionCount(_ channel: Snowflake) -> Int { readStates[channel]?.mentionCount ?? 0 }

    struct GuildBadge: Equatable {
        var unread: Bool
        var mentions: Int
    }

    func badge(for guildID: Snowflake) -> GuildBadge {
        _ = readStates; _ = channels; _ = guildSettings; _ = notificationTimeRevision; _ = joinedThreads // observation dependencies
        if let cached = badgeCache[guildID], cached.revision == derivedRevision { return cached.badge }
        let badge = computeBadge(for: guildID)
        badgeCache[guildID] = (derivedRevision, badge)
        return badge
    }

    /// Exactly what the sidebar shows: each visible channel's own state plus
    /// its thread rollup, so every rail mention traces to a row.
    private func computeBadge(for guildID: Snowflake) -> GuildBadge {
        var unread = false
        var mentions = 0
        let guildMuted = isMuted(guild: guildID)
        for section in sections(for: guildID) {
            for channel in section.channels {
                let rollup = threadRollup(for: channel.id)
                mentions += mentionCount(channel.id) + rollup.mentions
                if !guildMuted, !unread, showsUnread(channel) || rollup.unread { unread = true }
            }
        }
        return GuildBadge(unread: unread, mentions: mentions)
    }

    /// Mentions plus unread DMs: the app icon badge.
    var totalBadge: Int {
        var total = 0
        for (id, state) in readStates where state.mentionCount > 0 {
            if let channel = channels[id], channel.guildID == nil || canView(channel) { total += state.mentionCount }
        }
        return total
    }

    var unreadDMs: [Channel] {
        privateChannels.filter { mentionCount($0.id) > 0 }
    }

    func typingUsers(in channel: Snowflake) -> [Snowflake] {
        let cutoff = Date.now.addingTimeInterval(-10)
        return (typing[channel] ?? [:]).filter { $0.value > cutoff && $0.key != me?.id }.map(\.key)
    }

    func voiceStates(in channel: Snowflake, guild: Snowflake) -> [VoiceState] {
        (voiceStates[guild] ?? [:]).values.filter { $0.channelID == channel }
    }

    var myVoiceState: VoiceState? {
        guard let me else { return nil }
        for states in voiceStates.values { if let state = states[me.id], state.channelID != nil { return state } }
        return nil
    }

    // MARK: Apply

    func reset() {
        resetPeople()
        resetReadOperations()
        resetPins()
        settingsSnapshotVersion &+= 1
        settingsVersions = [:]
        me = nil; guilds = [:]; guildOrder = []; folders = []; channels = [:]; privateChannelOrder = []
        users = [:]; myMembers = [:]; members = [:]; readStates = [:]; guildSettings = [:]; voiceStates = [:]
        typing = [:]; memberLists = [:]; presences = [:]; isReady = false; joinedThreads = []; knownAbsentThreadMemberships = []
    }

    /// Draws the last known state before the gateway connects. READY replaces it.
    func apply(snapshot: StoreSnapshot) {
        guard !isReady else { return }
        resetPeople()
        resetReadOperations()
        resetPins()
        joinedThreads = Set(snapshot.channels.filter { $0.member != nil }.map(\.id))
        knownAbsentThreadMemberships = []
        settingsSnapshotVersion &+= 1
        settingsVersions = [:]
        me = snapshot.me
        guilds = Dictionary(snapshot.guilds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guildOrder = snapshot.guildOrder
        folders = snapshot.folders
        channels = Dictionary(snapshot.channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        users = Dictionary(snapshot.users.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for relationship in snapshot.relationships ?? [] { applyRelationship(relationship) }
        myMembers = snapshot.myMembers
        readStates = Dictionary(snapshot.readStates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guildSettings = Dictionary(snapshot.guildSettings.map { ($0.guildID ?? 0, $0) }, uniquingKeysWith: { a, _ in a })
        sortPrivateChannels()
    }

    func apply(ready: ReadyPayload) {
        resetPeople()
        presences = [:]
        resetReadOperations()
        resetPins()
        readServerFloor = ready.readStateVersion
        settingsSnapshotVersion &+= 1
        settingsVersions = [:]
        var users: [Snowflake: User] = [:]
        for user in ready.users { users[user.id] = user }
        users[ready.user.id] = ready.user
        var channels: [Snowflake: Channel] = [:]
        var guilds: [Snowflake: Guild] = [:]
        var myMembers: [Snowflake: Member] = [:]
        var voice: [Snowflake: [Snowflake: VoiceState]] = [:]
        var joined = Set<Snowflake>()
        for (index, guild) in ready.guilds.enumerated() {
            var copy = guild
            for channel in guild.channels { channels[channel.id] = channel }
            for thread in guild.threads {
                channels[thread.id] = thread
                if thread.member != nil { joined.insert(thread.id) }
            }
            copy.channels = []
            copy.threads = []
            guilds[guild.id] = copy
            if index < ready.mergedMembers.count,
               let mine = ready.mergedMembers[index].first(where: { $0.userID == ready.user.id }) {
                myMembers[guild.id] = mine
            }
            var states: [Snowflake: VoiceState] = [:]
            for state in guild.voiceStates { states[state.userID] = state }
            voice[guild.id] = states
        }
        for channel in ready.privateChannels {
            channels[channel.id] = channel
            for user in channel.recipients ?? [] { users[user.id] = user }
        }
        var readStates: [Snowflake: ReadState] = [:]
        for state in ready.readStates where state.readStateType == 0 { readStates[state.id] = state }
        var settings: [Snowflake: UserGuildSettings] = [:]
        for entry in ready.guildSettings { settings[entry.guildID ?? 0] = entry }

        self.me = ready.user
        self.knownAbsentThreadMemberships = []
        self.joinedThreads = joined
        self.users = users
        for relationship in ready.relationships { applyRelationship(relationship) }
        self.channels = channels
        self.guilds = guilds
        self.guildOrder = ready.guilds.map(\.id)
        self.myMembers = myMembers
        self.voiceStates = voice
        self.readStates = readStates
        self.guildSettings = settings
        self.members = [:]
        self.memberLists = [:]
        if let proto = ready.settingsProto, let parsed = ProtoSettings.guildFolders(base64: proto) {
            folders = parsed.folders
        }
        sortPrivateChannels()
        isReady = true
        log.info("READY: \(guilds.count) guilds, \(channels.count) channels, \(readStates.count) read states, \(self.folders.count) folders")
    }

    func apply(supplemental: ReadySupplemental) {
        let order = guildOrder
        for (index, list) in supplemental.mergedMembers.enumerated() where index < order.count {
            if let me, let mine = list.first(where: { $0.userID == me.id }) { memberFactVersions[order[index], default: 0] &+= 1; myMembers[order[index]] = mine }
        }
        var presences = self.presences
        for presence in supplemental.friendPresences {
            if let id = presence.userID ?? presence.user?.id { if let status = presence.status { presences[id] = status }
                if let user = presence.user { remember(person: user.fields, id: user.id, fromGateway: true) } }
        }
        self.presences = presences
    }

    private func sortPrivateChannels() {
        privateChannelOrder = channels.values.filter { $0.type.isPrivate }
            .sorted { ($0.lastMessageID ?? $0.id) > ($1.lastMessageID ?? $1.id) }
            .map(\.id)
    }

    func upsert(guild: Guild) {
        deletedFactGuilds.remove(guild.id)
        guildFactVersions[guild.id, default: 0] &+= 1
        var copy = guild
        if copy.defaultMessageNotifications == nil {
            copy.defaultMessageNotifications = guilds[guild.id]?.defaultMessageNotifications
        }
        for channel in guild.channels { deletedFactChannels.remove(channel.id); changedChannel(channel.id); channels[channel.id] = channel }
        for thread in guild.threads {
            deletedFactChannels.remove(thread.id)
            changedChannel(thread.id)
            channels[thread.id] = thread
            if thread.member != nil { joinedThreads.insert(thread.id) }
        }
        copy.channels = []
        copy.threads = []
        guilds[guild.id] = copy
        if !guildOrder.contains(guild.id) { guildOrder.append(guild.id) }
        var states: [Snowflake: VoiceState] = [:]
        for state in guild.voiceStates { states[state.userID] = state }
        voiceStates[guild.id] = states
    }

    func upsert(channel: Channel) {
        let previous = channels[channel.id]
        deletedFactChannels.remove(channel.id)
        changedChannel(channel.id)
        var channel = channel
        // Updates omit fields the list relies on; keep the known ones.
        if let existing = channels[channel.id] {
            // A partial update cannot silently remove the safety label.
            if channel.nsfw == nil { channel.nsfw = existing.nsfw }
            if channel.parentID == nil { channel.parentID = existing.parentID }
            if channel.ownerID == nil { channel.ownerID = existing.ownerID }
            if channel.permissionOverwrites == nil { channel.permissionOverwrites = existing.permissionOverwrites }
            if channel.rateLimitPerUser == nil { channel.rateLimitPerUser = existing.rateLimitPerUser }
            if var metadata = channel.threadMetadata {
                if metadata.archived == nil { metadata.archived = existing.threadMetadata?.archived }
                if metadata.locked == nil { metadata.locked = existing.threadMetadata?.locked }
                if metadata.archiveTimestamp == nil { metadata.archiveTimestamp = existing.threadMetadata?.archiveTimestamp }
                if metadata.createTimestamp == nil { metadata.createTimestamp = existing.threadMetadata?.createTimestamp }
                channel.threadMetadata = metadata
            } else { channel.threadMetadata = existing.threadMetadata }
            if channel.lastMessageID == nil { channel.lastMessageID = existing.lastMessageID }
            if channel.recipients == nil { channel.recipients = existing.recipients }
            if channel.recipientIDs == nil { channel.recipientIDs = existing.recipientIDs }
            if channel.member == nil { channel.member = existing.member }
            if channel.guildID == nil, !channel.type.isPrivate { channel.guildID = existing.guildID }
        }
        // Partial thread updates may omit guild_id; the parent knows it.
        if channel.guildID == nil, channel.type.isThread, let parent = channel.parentID {
            channel.guildID = channels[parent]?.guildID
        }
        channels[channel.id] = channel
        if channel.type == .dm {
            for id in channel.recipients.map({ $0.map(\.id) }) ?? channel.recipientIDs ?? [] { dmVersions[id, default: 0] &+= 1 }
        }
        if channel.member != nil { joinedThreads.insert(channel.id) }
        for user in channel.recipients ?? [] { users[user.id] = user }
        if channel.type.isPrivate { sortPrivateChannels() }
        if previous?.nsfw != channel.nsfw || previous?.parentID != channel.parentID {
            onPrivacyChange?()
        }
    }

    /// A confirmed join or leave. Leaving also forgets the READY membership
    /// record, so the thread never reads as joined again from stale data.
    func setThreadMembership(_ id: Snowflake, joined: Bool) {
        changedChannel(id)
        if joined { recordThreadMembership(id, joinedAt: nil); return }
        joinedThreads.remove(id)
        knownAbsentThreadMemberships.insert(id)
        if var thread = channels[id], thread.member != nil {
            changedChannel(id)
            thread.member = nil
            channels[id] = thread
        }
    }

    /// A channel or thread that no longer exists (confirmed delete or gateway).
    func removeChannel(_ id: Snowflake) {
        deletedFactChannels.insert(id)
        changedChannel(id)
        if let channel = channels[id], channel.type == .dm {
            for user in channel.recipients.map({ $0.map(\.id) }) ?? channel.recipientIDs ?? [] { dmVersions[user, default: 0] &+= 1 }
        }
        channels[id] = nil
        knownAbsentThreadMemberships.remove(id)
        joinedThreads.remove(id)
        sortPrivateChannels()
    }

    /// Threads and forum posts loaded over REST join the known channels.
    func remember(threads: [Channel]) {
        for thread in threads where channels[thread.id] == nil || channels[thread.id] != thread { upsert(channel: thread) }
        if threads.contains(where: { $0.member != nil }) { scheduleMuteExpiry() }
    }

    /// All membership event shapes merge the same current-user reference.
    /// Missing fields keep known authority; an explicit new join replaces it.
    /// Notification settings the event carried are authoritative (gateway).
    private func recordThreadMembership(_ id: Snowflake, joinedAt stamp: String?,
                                        settings: ThreadMemberSettingsUpdate = ThreadMemberSettingsUpdate()) {
        changedChannel(id)
        joinedThreads.insert(id)
        knownAbsentThreadMemberships.remove(id)
        guard var thread = channels[id] else { return }
        var member = thread.member ?? ThreadMemberRef(joinTimestamp: nil)
        member.joinTimestamp = stamp ?? member.joinTimestamp
        member = settings.applied(to: member)
        for field in settings.fieldNames {
            threadSettingsVersion &+= 1
            threadSettingsVersions[id, default: [:]][field] = threadSettingsVersion
        }
        guard thread.member != member || settings.hasSettings else { return }
        changedChannel(id)
        thread.member = member
        channels[id] = thread
        if settings.hasSettings { scheduleMuteExpiry() }
    }

    // MARK: Thread notification settings

    @ObservationIgnored private var threadSettingsVersions: [Snowflake: [String: UInt64]] = [:]
    @ObservationIgnored private var threadSettingsVersion: UInt64 = 0

    /// The current user's thread member, when joined.
    func threadMember(_ id: Snowflake) -> ThreadMemberRef? {
        guard joinedThreads.contains(id) else { return nil }
        return channels[id]?.member ?? ThreadMemberRef(joinTimestamp: nil)
    }

    func threadSettingsVersions(for id: Snowflake) -> [String: UInt64] { threadSettingsVersions[id] ?? [:] }

    /// A confirmed settings response. Only fields this request asked for are
    /// applied, and only if no newer (gateway) value arrived since it began.
    /// Nothing is applied to a thread the user has since left.
    func applyThreadSettings(_ update: ThreadMemberSettingsUpdate, thread id: Snowflake,
                             requested: Set<String>, versions: [String: UInt64]) {
        guard joinedThreads.contains(id), var thread = channels[id] else { return }
        let fresh = update.fieldNames.intersection(requested).filter {
            (threadSettingsVersions[id]?[$0] ?? 0) == (versions[$0] ?? 0)
        }
        guard !fresh.isEmpty else { return }
        for field in fresh {
            threadSettingsVersion &+= 1
            threadSettingsVersions[id, default: [:]][field] = threadSettingsVersion
        }
        let member = update.applied(to: thread.member ?? ThreadMemberRef(joinTimestamp: nil), only: fresh)
        changedChannel(id)
        thread.member = member
        channels[id] = thread
        scheduleMuteExpiry()
    }

    func remember(messageAuthors messages: [Message]) {
        var known = users
        for message in messages {
            known[message.author.id] = known[message.author.id] ?? message.author
            for user in message.mentions where known[user.id] == nil { known[user.id] = user }
            if let ref = message.referencedMessage?.message, known[ref.author.id] == nil { known[ref.author.id] = ref.author }
        }
        if known.count != users.count { users = known }
        for message in messages {
            if let guild = message.guildID ?? channels[message.channelID]?.guildID, let member = message.member {
                var copy = member
                copy.user = message.author
                copy.userID = message.author.id
                members[guild, default: [:]][message.author.id] = copy
            }
        }
    }

    func handle(_ dispatch: GatewayDispatch) {
        do {
            switch dispatch.name {
            case "RELATIONSHIP_ADD", "RELATIONSHIP_UPDATE", "RELATIONSHIP_REMOVE":
                applyRelationship(try dispatch.decode(Relationship.self), remove: dispatch.name == "RELATIONSHIP_REMOVE")
            case "READY_SUPPLEMENTAL":
                apply(supplemental: try dispatch.decode(ReadySupplemental.self))
            case "GUILD_CREATE":
                upsert(guild: try dispatch.decode(Guild.self))
            case "GUILD_UPDATE":
                struct Update: Decodable {
                    var id: Snowflake
                    var name: String?
                    var icon: String?
                    var iconWasProvided: Bool
                    var roles: [Role]?
                    var properties: GuildProperties?
                    var ownerID: Snowflake?
                    var defaultMessageNotifications: Int?
                    enum CodingKeys: String, CodingKey {
                        case id, name, icon, roles, properties
                        case ownerID = "owner_id"
                        case defaultMessageNotifications = "default_message_notifications"
                    }
                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: CodingKeys.self)
                        id = try c.decode(Snowflake.self, forKey: .id)
                        name = try c.decodeIfPresent(String.self, forKey: .name)
                        iconWasProvided = c.contains(.icon)
                        icon = try c.decodeIfPresent(String.self, forKey: .icon)
                        roles = try c.decodeIfPresent([Role].self, forKey: .roles)
                        properties = try c.decodeIfPresent(GuildProperties.self, forKey: .properties)
                        ownerID = try c.decodeIfPresent(Snowflake.self, forKey: .ownerID) ?? properties?.ownerID
                        defaultMessageNotifications = try c.decodeIfPresent(Int.self, forKey: .defaultMessageNotifications)
                    }
                }
                let update = try dispatch.decode(Update.self)
                guildFactVersions[update.id, default: 0] &+= 1
                if var guild = guilds[update.id] {
                    if let name = update.name { guild.name = name }
                    if update.iconWasProvided { guild.icon = update.icon }
                    if let roles = update.roles { guild.roles = roles }
                    if let owner = update.ownerID { guild.ownerID = owner }
                    if let level = update.defaultMessageNotifications ?? update.properties?.defaultMessageNotifications {
                        guild.defaultMessageNotifications = level
                    }
                    guilds[update.id] = guild
                }
            case "GUILD_DELETE":
                let deleted = try dispatch.decode(GuildDelete.self)
                guildFactVersions[deleted.id, default: 0] &+= 1
                if deleted.unavailable == true { guilds[deleted.id]?.unavailable = true }
                if deleted.unavailable != true {
                    deletedFactGuilds.insert(deleted.id)
                    myMembers[deleted.id] = nil
                    guilds[deleted.id] = nil
                    guildOrder.removeAll { $0 == deleted.id }
                    for channel in channels.values where channel.guildID == deleted.id { changedChannel(channel.id) }
                    channels = channels.filter { $0.value.guildID != deleted.id }
                }
            case "GUILD_ROLE_CREATE", "GUILD_ROLE_UPDATE":
                let event = try dispatch.decode(GuildRoleEvent.self)
                guildFactVersions[event.guildID, default: 0] &+= 1
                if let role = event.role, var guild = guilds[event.guildID] {
                    guild.roles.removeAll { $0.id == role.id }
                    guild.roles.append(role)
                    guilds[event.guildID] = guild
                }
            case "GUILD_ROLE_DELETE":
                let event = try dispatch.decode(GuildRoleEvent.self)
                guildFactVersions[event.guildID, default: 0] &+= 1
                if let id = event.roleID { guilds[event.guildID]?.roles.removeAll { $0.id == id } }
            case "GUILD_MEMBER_ADD", "GUILD_MEMBER_UPDATE":
                let update = try dispatch.decode(GuildMemberUpdate.self)
                let member = update.applying(to: member(update.user.id, in: update.guildID))
                if update.user.id == me?.id { memberFactVersions[update.guildID, default: 0] &+= 1; myMembers[update.guildID] = member }
                else { members[update.guildID, default: [:]][update.user.id] = member }
            case "GUILD_MEMBER_REMOVE":
                struct Removed: Decodable { var guild_id: Snowflake; var user: User }
                let removed = try dispatch.decode(Removed.self)
                if removed.user.id == me?.id { memberFactVersions[removed.guild_id, default: 0] &+= 1; myMembers[removed.guild_id] = nil }
                else { members[removed.guild_id]?[removed.user.id] = nil }
            case "CHANNEL_CREATE", "CHANNEL_UPDATE", "THREAD_CREATE", "THREAD_UPDATE":
                upsert(channel: try dispatch.decode(Channel.self))
            case "CHANNEL_DELETE", "THREAD_DELETE":
                struct Deleted: Decodable { var id: Snowflake }
                removeChannel(try dispatch.decode(Deleted.self).id)
            case "THREAD_LIST_SYNC":
                let sync = try dispatch.decode(ThreadListSync.self)
                for var thread in sync.threads {
                    thread.guildID = sync.guildID
                    upsert(channel: thread)
                }
                for entry in sync.members ?? [] {
                    if let id = entry.id { recordThreadMembership(id, joinedAt: entry.joinTimestamp, settings: entry.settings) }
                }
            case "THREAD_MEMBER_UPDATE":
                struct Mine: Decodable {
                    var id: Snowflake?
                    var joinTimestamp: String?
                    enum CodingKeys: String, CodingKey { case id; case joinTimestamp = "join_timestamp" }
                }
                let mine = try dispatch.decode(Mine.self)
                if let id = mine.id {
                    // Also carries the thread's notification preference (flags, muted, mute_config).
                    let settings = (try? dispatch.decode(ThreadMemberSettingsUpdate.self)) ?? ThreadMemberSettingsUpdate()
                    recordThreadMembership(id, joinedAt: mine.joinTimestamp, settings: settings)
                }
            case "THREAD_MEMBERS_UPDATE":
                let update = try dispatch.decode(ThreadMembersUpdate.self)
                if let me = me?.id {
                    if let added = update.addedMembers?.first(where: { $0.userID == me }) {
                        recordThreadMembership(update.id, joinedAt: added.joinTimestamp)
                    }
                    if update.removedMemberIDs?.contains(me) == true { setThreadMembership(update.id, joined: false) }
                }
            case "MESSAGE_UPDATE", "MESSAGE_DELETE", "MESSAGE_DELETE_BULK":
                struct Changed: Decodable { var channel_id: Snowflake }
                let channel = try dispatch.decode(Changed.self).channel_id
                messageContentRevisions[channel, default: 0] &+= 1
            case "MESSAGE_CREATE":
                let message = try dispatch.decode(Message.self)
                received(message)
            case "MESSAGE_ACK":
                let ack = try dispatch.decode(MessageAck.self)
                applyReadEcho(ack)
            case "CHANNEL_PINS_UPDATE":
                applyPinsUpdate(try dispatch.decode(ChannelPinsUpdate.self))
            case "TYPING_START":
                let event = try dispatch.decode(TypingStart.self)
                typing[event.channelID, default: [:]][event.userID] = .now
                if let member = event.member, let guild = event.guildID, let user = member.user {
                    rememberGatewayMember(member, guild: guild)
                    users[user.id] = user
                }
                pruneTypingSoon(event.channelID)
            case "VOICE_STATE_UPDATE":
                let state = try dispatch.decode(VoiceState.self)
                let guild = state.guildID ?? 0
                if state.channelID == nil { voiceStates[guild]?[state.userID] = nil }
                else { voiceStates[guild, default: [:]][state.userID] = state }
                if let member = state.member, let user = member.user {
                    users[user.id] = user
                    if let guildID = state.guildID { rememberGatewayMember(member, guild: guildID) }
                }
            case "USER_GUILD_SETTINGS_UPDATE":
                let update = try dispatch.decode(GuildSettingsUpdate.self)
                guard update.fields["guild_id"] != nil else { break }
                try applyNotificationSettings(update, resource: update.guildID)
            case "USER_SETTINGS_PROTO_UPDATE":
                let update = try dispatch.decode(SettingsProtoUpdate.self)
                if update.settings.type == 1, update.partial != true,
                   let parsed = ProtoSettings.guildFolders(base64: update.settings.proto) {
                    folders = parsed.folders
                }
            case "PRESENCE_UPDATE":
                let presence = try dispatch.decode(PresenceUpdate.self)
                if let status = presence.status { presences[presence.user.id] = status }
                remember(person: presence.user.fields, id: presence.user.id, fromGateway: true)
            case "GUILD_MEMBER_LIST_UPDATE":
                apply(memberList: try dispatch.decode(MemberListUpdate.self))
            case "GUILD_EMOJIS_UPDATE":
                struct Emojis: Decodable { var guild_id: Snowflake; var emojis: [Emoji] }
                let update = try dispatch.decode(Emojis.self)
                guilds[update.guild_id]?.emojis = update.emojis
            case "GUILD_MEMBERS_CHUNK":
                // The answer to a member search (op 8), for autocomplete.
                struct Chunk: Decodable { var guild_id: Snowflake; var members: [Member] }
                let chunk = try dispatch.decode(Chunk.self)
                for member in chunk.members {
                    guard let user = member.user else { continue }
                    users[user.id] = user
                    rememberGatewayMember(member, guild: chunk.guild_id)
                }
                memberSearchRevision += 1
            default:
                break
            }
        } catch {
            log.error("decode \(dispatch.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func received(_ message: Message) {
        let boundary = channels[message.channelID].flatMap(readBoundary)
        if var channel = channels[message.channelID] {
            changedChannel(message.channelID)
            channel.lastMessageID = message.id
            channels[message.channelID] = channel
            if channel.type.isPrivate { sortPrivateChannels() }
        }
        typing[message.channelID]?[message.author.id] = nil
        if let guild = message.guildID, let member = message.member {
            var copy = member
            copy.user = message.author
            copy.userID = message.author.id
            rememberGatewayMember(copy, guild: guild)
        }
        users[message.author.id] = message.author
        for user in message.mentions where users[user.id] == nil { users[user.id] = user }
        let held = manualUnreadChannels.contains(message.channelID) || pendingUnreadChannels.contains(message.channelID)
        if message.author.id == me?.id, !held {
            readVersions[message.channelID, default: ReadVersion()].boundary += 1
            readVersions[message.channelID, default: ReadVersion()].mentions += 1
            // Our own message counts as read.
            readStates[message.channelID] = ReadState(id: message.channelID, lastMessageID: message.id, mentionCount: 0)
            onAcceptedRead?(message.channelID, message.id)
        } else if (held || pendingReadChannels.contains(message.channelID) || !(message.channelID == visibleChannel && visibleIsLive)), mentionsMe(message) {
            readVersions[message.channelID, default: ReadVersion()].mentions += 1
            readVersions[message.channelID, default: ReadVersion()].mentionArrivals += 1
            var state = readStates[message.channelID] ?? ReadState(id: message.channelID, lastMessageID: boundary, mentionCount: 0)
            state.mentionCount += 1
            readStates[message.channelID] = state
        } else if message.channelID != visibleChannel, readStates[message.channelID] == nil {
            readStates[message.channelID] = ReadState(id: message.channelID, lastMessageID: boundary, mentionCount: 0)
        }
        onMessageCreate?(message)
    }

    /// Mentions that count toward badges: direct, role, @everyone (unless
    /// suppressed) and every message in a DM.
    func mentionsMe(_ message: Message) -> Bool {
        guard let me, message.author.id != me.id else { return false }
        guard let channel = channels[message.channelID] else { return false }
        if channel.type.isPrivate { return !isMuted(channel) }
        if message.mentions.contains(where: { $0.id == me.id }) { return true }
        let settings = guildSettings[channel.guildID ?? 0]
        if message.mentionEveryone, settings?.suppressEveryone != true { return true }
        if let guild = channel.guildID, settings?.suppressRoles != true,
           !Set(message.mentionRoles).isDisjoint(with: myMembers[guild]?.roles ?? []) { return true }
        return false
    }

    /// Whether a new message should raise a notification, following the
    /// guild/channel notification level and mutes.
    func shouldNotify(_ message: Message) -> Bool {
        guard contentAccess(to: message.channelID).permitsContent else { return false }
        guard let me, message.author.id != me.id, let channel = channels[message.channelID] else { return false }
        guard !isBlocked(message.author.id), !isMuted(channel), !isMuted(guild: channel.guildID ?? 0) else { return false }
        let level = effectiveNotificationLevel(.channel(guild: channel.guildID, channel: channel.id)).level.rawValue
        switch level {
        case 0: return true
        case 1:
            if channel.type.isPrivate { return message.mentions.contains { $0.id == me.id } || message.mentionEveryone }
            return mentionsMe(message)
        default: return false
        }
    }

    func markRead(_ channel: Snowflake, upTo message: Snowflake) {
        guard !manualUnreadChannels.contains(channel), !pendingUnreadChannels.contains(channel) else { return }
        var state = readStates[channel] ?? ReadState(id: channel, lastMessageID: nil, mentionCount: 0)
        guard state.lastMessageID.map({ $0 < message }) ?? true || state.mentionCount > 0 else { return }
        readVersions[channel, default: ReadVersion()].boundary += 1
        readVersions[channel, default: ReadVersion()].mentions += 1
        let advancedBoundary = message > (state.lastMessageID ?? 0)
        state.lastMessageID = max(message, state.lastMessageID ?? 0)
        state.mentionCount = 0
        localReadProgress[channel] = (state.lastMessageID ?? message, readVersion(channel).boundary)
        readStates[channel] = state
        if advancedBoundary, let boundary = state.lastMessageID { onAcceptedRead?(channel, boundary) }
    }

    private func pruneTypingSoon(_ channel: Snowflake) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10.5))
            guard let self else { return }
            let cutoff = Date.now.addingTimeInterval(-10)
            if let entries = self.typing[channel] {
                let live = entries.filter { $0.value > cutoff }
                if live.count != entries.count { self.typing[channel] = live }
            }
        }
    }

    // MARK: Member list

    private func apply(memberList update: MemberListUpdate) {
        var state = memberLists[update.guildID].flatMap { $0.id == update.id ? $0 : nil } ?? MemberListState(id: update.id)
        state.memberCount = update.memberCount ?? state.memberCount
        state.onlineCount = update.onlineCount ?? state.onlineCount
        let groupCounts = Dictionary(update.groups.map { ($0.id, $0.count ?? 0) }, uniquingKeysWith: { a, _ in a })
        func row(_ item: MemberListUpdate.Item) -> MemberListRow {
            switch item {
            case .group(let group):
                return .group(id: group.id, title: groupTitle(group.id, guild: update.guildID), count: groupCounts[group.id] ?? group.count ?? 0)
            case .member(let member, let status):
                if let user = member.user {
                    users[user.id] = user
                    rememberGatewayMember(member, guild: update.guildID)
                    presences[user.id] = status
                }
                return .member(member, status)
            }
        }
        func ensure(_ count: Int) { if state.slots.count < count { state.slots += Array(repeating: nil, count: count - state.slots.count) } }
        for op in update.ops {
            switch op.op {
            case "SYNC":
                guard let range = op.range, range.count == 2, range[0] >= 0 else { continue }
                let items = (op.items ?? []).map(row)
                ensure(range[0] + items.count)
                for (offset, item) in items.enumerated() { state.slots[range[0] + offset] = item }
            case "INSERT":
                if let index = op.index, let item = op.item, index >= 0 {
                    ensure(index)
                    state.slots.insert(row(item), at: min(index, state.slots.count))
                }
            case "UPDATE":
                if let index = op.index, let item = op.item, index >= 0 { ensure(index + 1); state.slots[index] = row(item) }
            case "DELETE":
                if let index = op.index, index >= 0, index < state.slots.count { state.slots.remove(at: index) }
            case "INVALIDATE":
                // Keep positions: later ops refer to the original indices.
                if let range = op.range, range.count == 2, range[0] >= 0 {
                    for index in range[0]...max(range[0], range[1]) where index < state.slots.count { state.slots[index] = nil }
                }
            default:
                break
            }
        }
        // Refresh group counts on existing headers.
        state.slots = state.slots.map { slot in
            if case .group(let id, let title, _)? = slot, let count = groupCounts[id] { return .group(id: id, title: title, count: count) }
            return slot
        }
        memberLists[update.guildID] = state
    }

    private func groupTitle(_ id: String, guild: Snowflake) -> String {
        switch id {
        case "online": return "Online"
        case "offline": return "Offline"
        default: return Snowflake(id).flatMap { role($0, in: guild)?.name } ?? id
        }
    }

    // MARK: Mock / cache

    func seed(members byGuild: [Snowflake: [Member]]) {
        for (guild, entries) in byGuild {
            for member in entries {
                guard let id = member.userID else { continue }
                members[guild, default: [:]][id] = member
                if let user = member.user { users[id] = user }
            }
        }
    }
}
