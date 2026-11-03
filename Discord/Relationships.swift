import Foundation

/// Raw fields preserve omission, explicit null and partial user payloads.
/// Only documented types 1–4 participate in Friends UI.
nonisolated struct Relationship: Codable, Hashable, Sendable, Identifiable {
    var fields: [String: JSONValue]
    var id: Snowflake
    var type: Int? {
        guard case .number(let value) = fields["type"] else { return nil }
        return Int(exactly: value)
    }
    var userFields: [String: JSONValue]? {
        guard case .object(let value) = fields["user"],
              let data = try? JSONEncoder().encode(value),
              let identity = try? JSONDecoder().decode(PartialUser.self, from: data), identity.id == id else { return nil }
        return value
    }
    init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
        guard let value = fields["id"] else { throw DiscordError.decoding("relationship id") }
        id = try JSONDecoder().decode(Snowflake.self, from: JSONEncoder().encode(value))
        discardInvalidUser()
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
    init(id: Snowflake, type: Int, user: User? = nil) {
        self.id = id
        fields = ["id": .string(id.description), "type": .number(Double(type))]
        if let user, user.id == id, let data = try? JSONEncoder().encode(user),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) { fields["user"] = value }
    }
    func merging(_ update: Relationship) -> Relationship {
        guard update.id == id else { return self }
        var result = self
        result.discardInvalidUser()
        for (key, value) in update.fields {
            if key == "user", value != .null {
                guard let partial = update.userFields else { continue }
                let old = result.userFields ?? [:]
                result.fields[key] = .object(old.merging(partial, uniquingKeysWith: { _, new in new }))
            } else { result.fields[key] = value }
        }
        return result
    }
    private mutating func discardInvalidUser() {
        if let user = fields["user"], user != .null, userFields == nil {
            // Rejected identity data must not survive to a later ID-only
            // update or an encoded snapshot.
            fields["user"] = nil
        }
    }
}

nonisolated enum RelationshipAction: String, CaseIterable, Sendable {
    case request, accept, decline, cancel, remove, block, unblock
    var title: String {
        switch self {
        case .request: "Add Friend"
        case .accept: "Accept Request"
        case .decline: "Decline Request"
        case .cancel: "Cancel Request"
        case .remove: "Remove Friend"
        case .block: "Block"
        case .unblock: "Unblock"
        }
    }
    var isDestructive: Bool { self == .remove || self == .block }
    var method: String { [.decline, .cancel, .remove, .unblock].contains(self) ? "DELETE" : "PUT" }
    var body: [String: JSONValue]? {
        method == "DELETE" ? nil : ["type": .number(self == .block ? 2 : self == .accept ? 1 : -1)]
    }
    func applies(to type: Int?) -> Bool {
        switch self {
        case .request: type == nil || type == 0 || type == 5 || type == 6
        case .accept, .decline: type == 3
        case .cancel: type == 4
        case .remove: type == 1
        case .block: type != 2
        case .unblock: type == 2
        }
    }
    var resultingType: Int? {
        switch self {
        case .request: 4
        case .accept: 1
        case .block: 2
        default: nil
        }
    }
}

nonisolated enum FriendsFilter: String, CaseIterable, Identifiable {
    case all = "All", online = "Online", pending = "Pending", blocked = "Blocked"
    var id: String { rawValue }
}

nonisolated struct FriendUsername: Equatable, Sendable {
    let value: String
    init?(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...32).contains(value.count), !value.contains(".."),
              value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 46 }) else { return nil }
        self.value = value
    }
    /// Userdoccers: migrated unique usernames use a null discriminator.
    var fields: [String: JSONValue] { ["username": .string(value), "discriminator": .null] }
}
