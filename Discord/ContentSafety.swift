import Foundation

/// Discord's channel labels apply to their threads and child channels too.
/// There is no in-app opt-in to age-restricted channels in this client.
enum ChannelContentAccess: Equatable {
    case allowed, ageRestricted, unavailable

    var permitsContent: Bool { self == .allowed }
    var explanation: String {
        switch self {
        case .allowed: return ""
        case .ageRestricted: return "Age-restricted channels are unavailable in Duocord."
        case .unavailable: return "Channel information is unavailable. Content stays hidden until it can be checked."
        }
    }
}

extension DiscordStore {
    func contentAccess(to id: Snowflake) -> ChannelContentAccess {
        guard let channel = channel(id) else { return .unavailable }
        return contentAccess(to: channel)
    }

    func contentAccess(to channel: Channel) -> ChannelContentAccess {
        var current = channel
        var visited = Set<Snowflake>()
        while visited.insert(current.id).inserted {
            if current.nsfw == true { return .ageRestricted }
            guard let parentID = current.parentID else {
                return current.type.isThread ? .unavailable : .allowed
            }
            guard let parent = self.channel(parentID), parent.guildID == current.guildID else {
                return .unavailable
            }
            current = parent
        }
        return .unavailable
    }
}
