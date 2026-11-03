import Foundation
import os

/// What the store needs to draw the app before the gateway is ready.
nonisolated struct StoreSnapshot: Codable, Sendable {
    var me: User
    var guilds: [Guild]
    var guildOrder: [Snowflake]
    var folders: [GuildFolder]
    var channels: [Channel]
    var users: [User]
    var myMembers: [Snowflake: Member]
    var readStates: [ReadState]
    var guildSettings: [UserGuildSettings]
    var relationships: [Relationship]? = nil
}

/// On-disk cache in Caches/: the last store snapshot and the newest page of
/// recently opened channels. Lets a cold start show the last conversation
/// immediately; the gateway and REST refresh it moments later. Contains
/// message content, so it is file-protected and removed on sign-out.
nonisolated enum SnapshotCache {
    private static let log = Logger(subsystem: "com.saphid.duocord.native", category: "cache")
    private static let queue = DispatchQueue(label: "duocord.cache", qos: .utility)

    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "duocord", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func write(_ data: Data, to name: String) {
        let url = directory.appending(path: name)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func save(_ snapshot: StoreSnapshot) {
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            write(data, to: "store.json")
        }
    }

    static func loadSnapshot() -> StoreSnapshot? {
        guard let data = try? Data(contentsOf: directory.appending(path: "store.json")) else { return nil }
        do {
            return try JSONDecoder().decode(StoreSnapshot.self, from: data)
        } catch {
            log.error("snapshot decode: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func save(messages: [Message], channel: Snowflake) {
        let page = Array(messages.suffix(50))
        queue.async {
            guard let data = try? JSONEncoder().encode(page) else { return }
            write(data, to: "messages-\(channel).json")
        }
    }

    static func loadMessages(channel: Snowflake) -> [Message]? {
        guard let data = try? Data(contentsOf: directory.appending(path: "messages-\(channel).json")) else { return nil }
        return try? JSONDecoder().decode([Message].self, from: data)
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }
}

extension DiscordStore {
    func snapshot() -> StoreSnapshot? {
        guard let me, isReady else { return nil }
        // Keep the snapshot small: categories and channels the user can see, DMs.
        let keptChannels = channels.values.filter { channel in
            if channel.type.isPrivate { return true }
            if channel.type.isThread { return false }
            return canView(channel)
        }
        var keptUsers: [Snowflake: User] = [me.id: me]
        for channel in keptChannels where channel.type.isPrivate {
            for user in recipients(of: channel) { keptUsers[user.id] = user }
        }
        for id in relationships.keys { if let user = users[id] { keptUsers[id] = user } }
        let keptReads = readStates.values.filter { channels[$0.id] != nil }
        return StoreSnapshot(me: me, guilds: Array(guilds.values), guildOrder: guildOrder, folders: folders,
                             channels: keptChannels, users: Array(keptUsers.values), myMembers: myMembers,
                             readStates: Array(keptReads), guildSettings: Array(guildSettings.values), relationships: Array(relationships.values))
    }
}
