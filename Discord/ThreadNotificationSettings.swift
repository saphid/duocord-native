import Foundation

/// A thread's notification preference lives on the current user's thread
/// member (`flags`, `muted`, `mute_config`), not in guild channel overrides.
/// Written with `PATCH channels/{thread}/thread-members/@me/settings`, which
/// requires membership, returns the thread member, or 204 when nothing
/// changed, and fires THREAD_MEMBER_UPDATE.
/// https://docs.discord.food/resources/channel#modify-thread-settings
nonisolated enum ThreadMemberFlags {
    /// Set by Discord, never by clients; preserved as is.
    static let hasInteracted = 1 << 0
    static let allMessages = 1 << 1
    static let onlyMentions = 1 << 2
    static let noMessages = 1 << 3
    static let notificationMask = allMessages | onlyMentions | noMessages

    /// None of the three notification flags means the thread inherits.
    static func level(_ flags: Int?) -> NotificationLevel {
        guard let flags else { return .inherit }
        if flags & allMessages != 0 { return .all }
        if flags & onlyMentions != 0 { return .mentions }
        if flags & noMessages != 0 { return .nothing }
        return .inherit
    }

    /// `current` with only its notification bits replaced (others, such as
    /// HAS_INTERACTED, kept).
    static func flags(_ current: Int, level: NotificationLevel) -> Int {
        let rest = current & ~notificationMask
        switch level {
        case .all: return rest | allMessages
        case .mentions: return rest | onlyMentions
        case .nothing: return rest | noMessages
        case .inherit: return rest
        }
    }
}

/// The settings fields a thread-member payload actually carried. Absent fields
/// stay absent; an explicit `mute_config: null` is a clear, not "unknown".
nonisolated struct ThreadMemberSettingsUpdate: Decodable, Equatable, Sendable {
    var flags: Int?
    var muted: Bool?
    /// nil: absent. .some(nil): explicitly cleared.
    var muteConfig: MuteConfig??
    var joinTimestamp: String?

    init(flags: Int? = nil, muted: Bool? = nil, muteConfig: MuteConfig?? = nil, joinTimestamp: String? = nil) {
        self.flags = flags; self.muted = muted; self.muteConfig = muteConfig; self.joinTimestamp = joinTimestamp
    }

    init(fields: [String: JSONValue]) {
        if case .number(let value) = fields["flags"], let flags = Int(exactly: value), flags >= 0 { self.flags = flags }
        if case .bool(let muted) = fields["muted"] { self.muted = muted }
        switch fields["mute_config"] {
        case .null?: muteConfig = .some(nil)
        case .object(let object)?:
            if let data = try? JSONEncoder().encode(JSONValue.object(object)),
               let config = try? JSONDecoder().decode(MuteConfig.self, from: data) { muteConfig = .some(config) }
        default: break
        }
        if case .string(let stamp) = fields["join_timestamp"] { joinTimestamp = stamp }
    }

    init(from decoder: Decoder) throws {
        let fields = (try? decoder.singleValueContainer().decode([String: JSONValue].self)) ?? [:]
        self.init(fields: fields)
    }

    var hasSettings: Bool { flags != nil || muted != nil || muteConfig != nil }

    /// Field names with independent freshness.
    var fieldNames: Set<String> {
        var names = Set<String>()
        if flags != nil { names.insert("flags") }
        if muted != nil { names.insert("muted") }
        if muteConfig != nil { names.insert("mute_config") }
        return names
    }

    /// `member` with the carried fields applied (others kept).
    func applied(to member: ThreadMemberRef, only allowed: Set<String>? = nil) -> ThreadMemberRef {
        var result = member
        if let flags, allowed?.contains("flags") ?? true { result.flags = flags }
        if let muted, allowed?.contains("muted") ?? true { result.muted = muted }
        if let muteConfig, allowed?.contains("mute_config") ?? true { result.muteConfig = muteConfig }
        return result
    }
}

extension NotificationPatch {
    /// The thread-member settings body for this patch, given the member's
    /// current flags. Only the edited preference is sent; server-only
    /// suppress options do not apply to threads.
    nonisolated func threadFields(currentFlags: Int) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if let level { fields["flags"] = .number(Double(ThreadMemberFlags.flags(currentFlags, level: level))) }
        if let muted {
            fields["muted"] = .bool(muted)
            fields["mute_config"] = muted ? .object([
                "end_time": muteConfig?.endTime.map(JSONValue.string) ?? .null,
                "selected_time_window": .number(Double(muteConfig?.selectedTimeWindow ?? -1))
            ]) : .null
        }
        return fields
    }
}

extension DiscordStore {
    /// A thread target whose preference can't be saved until the user joins.
    func needsThreadMembership(_ target: NotificationTarget) -> Bool {
        guard let id = target.channelID, channel(id)?.type.isThread == true else { return false }
        return threadMember(id) == nil
    }
}
