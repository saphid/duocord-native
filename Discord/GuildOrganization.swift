import Foundation

nonisolated enum GuildOrganizationError: Error, LocalizedError {
    case invalid, stale, noChange, malformed, missingVersion
    var errorDescription: String? {
        switch self {
        case .invalid: "This server can’t be moved there."
        case .stale: "The server list changed. Try the move again."
        case .noChange: "This server is already there."
        case .malformed: "Discord’s server order could not be safely read. Nothing was changed."
        case .missingVersion: "Discord did not provide a settings version. Nothing was changed."
        }
    }
}

/// Reordering retains folder names, colors, identities and all memberships.
/// Dropping before a server in a folder moves into that folder; nil is the rail end.
nonisolated struct GuildOrganization: Equatable, Sendable {
    private(set) var rows: [GuildFolder]
    var positions: [Snowflake] { rows.flatMap(\.guildIDs) }

    init(folders: [GuildFolder], membershipOrder: [Snowflake], departed: Set<Snowflake> = []) throws {
        let folders = folders.compactMap { original -> GuildFolder? in
            var row = original
            row.guildIDs.removeAll { departed.contains($0) }
            return row.guildIDs.isEmpty ? nil : row
        }
        let members = Set(membershipOrder)
        let listed = folders.flatMap(\.guildIDs)
        let ids = folders.compactMap(\.id)
        guard members.count == membershipOrder.count, !members.contains(0),
              Set(listed).count == listed.count, Set(listed).isSubset(of: members),
              Set(ids).count == ids.count,
              folders.allSatisfy({ $0.id != nil ? $0.guildIDs.count <= 100 : $0.guildIDs.count == 1 }) else {
            throw GuildOrganizationError.stale
        }
        rows = membershipOrder.reversed().filter { !listed.contains($0) }.map { GuildFolder(guildIDs: [$0]) }
            + folders.filter { !$0.guildIDs.isEmpty }
    }

    func moving(_ server: Snowflake, before target: Snowflake?, withinFolder: Bool = true) throws -> Self {
        guard positions.contains(server), target.map({ positions.contains($0) }) ?? true else { throw GuildOrganizationError.stale }
        if server == target {
            guard !withinFolder, let index = rows.firstIndex(where: { $0.guildIDs.contains(server) }), rows[index].id != nil else {
                throw GuildOrganizationError.noChange
            }
            var next = self
            next.rows[index].guildIDs.removeAll { $0 == server }
            next.rows.insert(GuildFolder(guildIDs: [server]), at: index)
            next.rows.removeAll { $0.guildIDs.isEmpty }
            return next
        }
        var next = self
        for index in next.rows.indices { next.rows[index].guildIDs.removeAll { $0 == server } }
        // Keep the destination folder even if removing its sole member emptied it.
        if let target, let index = next.rows.firstIndex(where: { $0.guildIDs.contains(target) }) {
            if withinFolder, next.rows[index].id != nil {
                guard next.rows[index].guildIDs.count < 100 else { throw GuildOrganizationError.invalid }
                let insertion = next.rows[index].guildIDs.firstIndex(of: target)!
                next.rows[index].guildIDs.insert(server, at: insertion)
            } else {
                next.rows.insert(GuildFolder(guildIDs: [server]), at: index)
            }
        } else {
            next.rows.append(GuildFolder(guildIDs: [server]))
        }
        next.rows.removeAll { $0.guildIDs.isEmpty }
        guard next != self else { throw GuildOrganizationError.noChange }
        return next
    }
}
