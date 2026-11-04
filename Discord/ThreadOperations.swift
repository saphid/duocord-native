import Foundation

/// Fields of `PATCH channels/{thread}` the thread menu changes. Only set
/// fields are sent, so a rename never reopens or unlocks a thread.
nonisolated struct ThreadPatch: Equatable, Sendable {
    var name: String?
    var archived: Bool?
    var locked: Bool?

    var fields: [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        if let name { body["name"] = .string(name) }
        if let archived { body["archived"] = .bool(archived) }
        if let locked { body["locked"] = .bool(locked) }
        return body
    }

    /// Discord's thread name rule: 1–100 characters after trimming.
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { return nil }
        return name
    }
}

/// One action from the thread menu.
nonisolated enum ThreadAction: Equatable, Sendable {
    case join, leave, rename(String), close, reopen, lock, unlock, delete

    var title: String {
        switch self {
        case .join: "Join Thread"
        case .leave: "Leave Thread"
        case .rename: "Edit Thread"
        case .close: "Close Thread"
        case .reopen: "Open Thread"
        case .lock: "Lock Thread"
        case .unlock: "Unlock Thread"
        case .delete: "Delete Thread"
        }
    }

    /// "Couldn’t <failure>."
    var failure: String {
        switch self {
        case .join: "join the thread"
        case .leave: "leave the thread"
        case .rename: "rename the thread"
        case .close: "close the thread"
        case .reopen: "open the thread"
        case .lock: "lock the thread"
        case .unlock: "unlock the thread"
        case .delete: "delete the thread"
        }
    }

    var patch: ThreadPatch? {
        switch self {
        case .rename(let name): ThreadPatch(name: name)
        case .close: ThreadPatch(archived: true)
        case .reopen: ThreadPatch(archived: false)
        case .lock: ThreadPatch(locked: true)
        case .unlock: ThreadPatch(locked: false)
        case .join, .leave, .delete: nil
        }
    }
}

/// What the current user may do to a thread, following Discord's rules:
/// - Manage Threads (from the parent channel; owner and administrators have
///   every permission) edits, closes, reopens, locks, unlocks and deletes.
/// - The thread's creator renames and closes their own unlocked thread.
/// - Anyone who can send in threads reopens an archived, unlocked thread.
/// - Joining and leaving need an active thread; a private thread is joined
///   only by thread managers (others are invited).
/// Manage Channels alone grants nothing here: Discord checks Manage Threads.
/// Locking, unlocking and renaming are offered on active threads only, since
/// Discord requires an archived thread to be reopened in the same request.
nonisolated struct ThreadCapabilities: Equatable, Sendable {
    var canJoin = false
    var canLeave = false
    var canRename = false
    var canClose = false
    var canReopen = false
    var canLock = false
    var canUnlock = false
    var canDelete = false

    static let none = ThreadCapabilities()

    static func evaluate(thread: Channel, me: Snowflake?, permissions: UInt64, canView: Bool, joined: Bool) -> ThreadCapabilities {
        guard thread.type.isThread, thread.guildID != nil, canView, let me else { return .none }
        let manage = permissions & Permission.manageThreads != 0
        let owner = thread.ownerID == me
        let archived = thread.threadMetadata?.archived == true
        let locked = thread.threadMetadata?.locked == true
        let sendInThreads = permissions & Permission.sendInThreads != 0
        var result = ThreadCapabilities()
        result.canJoin = !archived && !joined && (thread.type != .privateThread || manage)
        result.canLeave = !archived && joined
        result.canRename = !archived && (manage || (owner && !locked))
        result.canClose = !archived && (manage || (owner && !locked))
        result.canReopen = archived && (manage || (!locked && (owner || sendInThreads)))
        result.canLock = !archived && !locked && manage
        result.canUnlock = !archived && locked && manage
        result.canDelete = manage
        return result
    }

    func allows(_ action: ThreadAction) -> Bool {
        switch action {
        case .join: canJoin
        case .leave: canLeave
        case .rename: canRename
        case .close: canClose
        case .reopen: canReopen
        case .lock: canLock
        case .unlock: canUnlock
        case .delete: canDelete
        }
    }
}

extension DiscordStore {
    func isJoined(thread id: Snowflake) -> Bool { joinedThreads.contains(id) }

    func threadCapabilities(_ thread: Channel) -> ThreadCapabilities {
        ThreadCapabilities.evaluate(thread: thread, me: me?.id, permissions: permissions(in: thread),
                                    canView: canView(thread), joined: isJoined(thread: thread.id))
    }

    /// `https://discord.com/channels/<guild>/<thread>`, as Discord's Copy Link.
    nonisolated static func link(guild: Snowflake?, channel: Snowflake) -> String {
        "https://discord.com/channels/\(guild?.description ?? "@me")/\(channel)"
    }
}
