import Foundation

nonisolated enum NotificationLevel: Int, CaseIterable, Sendable {
    case all = 0, mentions = 1, nothing = 2, inherit = 3
    var title: String {
        switch self {
        case .all: "All Messages"
        case .mentions: "Mentions"
        case .nothing: "Nothing"
        case .inherit: "Inherit"
        }
    }
}

nonisolated enum MuteDuration: Int, CaseIterable, Sendable {
    case fifteenMinutes = 900, hour = 3600, eightHours = 28800, day = 86400, forever = -1
    var title: String {
        switch self {
        case .fifteenMinutes: "15 Minutes"
        case .hour: "1 Hour"
        case .eightHours: "8 Hours"
        case .day: "24 Hours"
        case .forever: "Until Turned Back On"
        }
    }
}

/// The private-channel settings resource is stored under 0 and addressed as
/// `@me` in Discord's route (its response's guild_id is null).
nonisolated enum NotificationTarget: Hashable, Sendable {
    case guild(Snowflake)
    case channel(guild: Snowflake?, channel: Snowflake)

    var resource: Snowflake {
        switch self {
        case .guild(let id): id
        case .channel(let guild, _): guild ?? 0
        }
    }
    var channelID: Snowflake? {
        if case .channel(_, let id) = self { return id }
        return nil
    }
    var routeID: String { resource == 0 ? "@me" : resource.description }
}

/// Only the field being edited is sent. In particular, channel_overrides is
/// keyed by snowflake, never a replacement array or a snapshot of all settings.
nonisolated struct NotificationPatch: Sendable {
    var muted: Bool?
    var muteConfig: MuteConfig?
    var level: NotificationLevel?
    var suppressEveryone: Bool?
    var suppressRoles: Bool?

    static func mute(_ duration: MuteDuration?, now: Date) -> Self {
        let end = duration.flatMap { $0 == .forever ? nil : now.addingTimeInterval(Double($0.rawValue)) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Self(muted: duration != nil,
                    muteConfig: MuteConfig(endTime: end.map { formatter.string(from: $0) },
                                           selectedTimeWindow: duration?.rawValue ?? -1))
    }

    func fields(for target: NotificationTarget) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if let muted {
            fields["muted"] = .bool(muted)
            fields["mute_config"] = .object([
                "end_time": muteConfig?.endTime.map(JSONValue.string) ?? .null,
                "selected_time_window": .number(Double(muteConfig?.selectedTimeWindow ?? -1))
            ])
        }
        if let level { fields["message_notifications"] = .number(Double(level.rawValue)) }
        if target.channelID == nil {
            if let suppressEveryone { fields["suppress_everyone"] = .bool(suppressEveryone) }
            if let suppressRoles { fields["suppress_roles"] = .bool(suppressRoles) }
        }
        if let id = target.channelID { return ["channel_overrides": .object([id.description: .object(fields)])] }
        return fields
    }
}

/// Presence-preserving HTTP/gateway update. Normalize array and keyed response
/// shapes before merging; absent fields must never acquire decoding defaults.
nonisolated struct GuildSettingsUpdate: Codable, Sendable {
    var fields: [String: JSONValue]
    init(fields: [String: JSONValue]) { self.fields = Self.normalized(fields) }
    init(from decoder: Decoder) throws {
        fields = Self.normalized(try decoder.singleValueContainer().decode([String: JSONValue].self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fields)
    }
    var guildID: Snowflake {
        switch fields["guild_id"] {
        case .string(let id): return Snowflake(UInt64(id) ?? 0)
        case .number(let id):
            guard let raw = UInt64(exactly: id) else { return 0 }
            return Snowflake(raw)
        default: return 0
        }
    }
    static func normalized(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var result = fields
        if case .array(let entries) = fields["channel_overrides"] {
            var keyed: [String: JSONValue] = [:]
            for case .object(let entry) in entries {
                if case .string(let id) = entry["channel_id"] { keyed[id] = .object(entry) }
            }
            result["channel_overrides"] = .object(keyed)
        }
        return result
    }
    /// Settings fields with independent authority: a gateway echo for one
    /// channel must not discard an HTTP result for a different channel.
    var leaves: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in fields where key != "guild_id" {
            if key == "channel_overrides" {
                // null, absent and malformed override containers carry no
                // updates. They must not erase unrelated channel settings.
                guard case .object(let channels) = value else { continue }
                for (id, entry) in channels {
                    guard UInt64(id) != nil, case .object(let fields) = entry else { continue }
                    for (field, value) in fields {
                        for (leaf, value) in Self.leaves(field, value: value, channel: true) {
                            result["\(id)/\(leaf)"] = value
                        }
                    }
                }
            } else {
                result.merge(Self.leaves(key, value: value, channel: false)) { _, new in new }
            }
        }
        return result
    }

    private static func leaves(_ field: String, value: JSONValue, channel: Bool) -> [String: JSONValue] {
        if field == "mute_config" {
            // An explicit clear owns both descendants. A partial echo owns only
            // its valid members, leaving HTTP free to fill the other member.
            if case .null = value {
                return ["mute_config/end_time": .null, "mute_config/selected_time_window": .null]
            }
            guard case .object(let config) = value else { return [:] }
            var leaves: [String: JSONValue] = [:]
            for (member, value) in config {
                switch (member, value) {
                case ("end_time", .null), ("selected_time_window", .null): break
                case ("end_time", .string(let end)) where DiscordDate.parse(end) != nil: break
                case ("selected_time_window", .number(let window)) where Int(exactly: window).map({ $0 >= -1 }) == true: break
                default: continue
                }
                leaves["mute_config/\(member)"] = value
            }
            return leaves
        }
        switch (field, value) {
        case ("muted", .bool): return [field: value]
        case ("suppress_everyone", .bool), ("suppress_roles", .bool): return channel ? [:] : [field: value]
        case ("message_notifications", .number(let level)): return [0.0, 1.0, 2.0, 3.0].contains(level) ? [field: value] : [:]
        default: return [:]
        }
    }

    static func applying(_ value: JSONValue, at leaf: String, to fields: [String: JSONValue]) -> [String: JSONValue] {
        var path = leaf.split(separator: "/").map(String.init)
        if let id = path.first, UInt64(id) != nil { path.insert("channel_overrides", at: 0) }
        var result = setting(value, at: path[...], in: fields)
        if path.count >= 2, path[path.count - 2] == "mute_config" {
            let configPath = Array(path.dropLast())
            var current = JSONValue.object(result)
            for key in configPath {
                guard case .object(let object) = current else { return result }
                current = object[key] ?? .null
            }
            if case .object(let config) = current,
               config.values.allSatisfy({ if case .null = $0 { return true }; return false }) {
                // Preserve explicit-null semantics after clearing the final
                // member, regardless of dictionary iteration order.
                result = setting(.null, at: configPath[...], in: result)
            }
        }
        return result
    }

    private static func setting(_ value: JSONValue, at path: ArraySlice<String>, in fields: [String: JSONValue]) -> [String: JSONValue] {
        guard let key = path.first else { return fields }
        var result = fields
        if path.count == 1 { result[key] = value }
        else {
            var child: [String: JSONValue] = [:]
            if case .object(let existing) = fields[key] { child = existing }
            result[key] = .object(setting(value, at: path.dropFirst(), in: child))
        }
        return result
    }

    static func mergeObject(_ base: [String: JSONValue], _ update: [String: JSONValue]) -> [String: JSONValue] {
        var result = base
        for (key, value) in update {
            if case .object(let next) = value, case .object(let old) = result[key] {
                result[key] = .object(mergeObject(old, next))
            } else { result[key] = value }
        }
        return result
    }
}
