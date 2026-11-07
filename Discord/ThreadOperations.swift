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

    /// The operation layer extends these established thread rules rather than
    /// maintaining another creator/archive policy. Unknown facts stay explicit.
    static func decision(_ action: ThreadAction, context: CapabilityContext,
                         permissions: PermissionResolution) -> CapabilityDecision {
        let thread = context.channel
        guard thread.type.isThread else { return .denied(.unsupportedChannel(thread.type), .threadPolicy) }
        guard let me = context.account?.id else { return .unknown(.account) }
        let visibility = permissions.requiring(Permission.viewChannel)
        guard visibility.isAllowed, let bits = permissions.permissions else { return visibility }
        if action != .delete, thread.threadMetadata?.archived == nil || thread.threadMetadata?.locked == nil {
            return .unknown(.threadState)
        }
        if (action == .join || action == .leave), context.membership == .unknown { return .unknown(.membership) }
        if bits & Permission.manageThreads == 0, thread.ownerID == nil {
            switch action {
            case .rename, .close, .reopen: return .unknown(.ownership)
            default: break
            }
        }
        if case .rename(let name) = action, ThreadPatch.validName(name) == nil { return .denied(.invalidPayload, .payload) }
        let known = evaluate(thread: thread, me: me, permissions: bits, canView: true, joined: context.membership == .joined)
        return known.allows(action) ? CapabilityDecision(state: .allowed, provenance: [.threadPolicy])
            : .denied(.threadActionUnavailable, .threadPolicy)
    }

    static func evaluate(context: CapabilityContext) -> ThreadCapabilities {
        var result = ThreadCapabilities()
        result.canJoin = DiscordOperation.thread(.join).evaluate(context).isAllowed
        result.canLeave = DiscordOperation.thread(.leave).evaluate(context).isAllowed
        result.canRename = DiscordOperation.thread(.rename(context.channel.name ?? "thread")).evaluate(context).isAllowed
        result.canClose = DiscordOperation.thread(.close).evaluate(context).isAllowed
        result.canReopen = DiscordOperation.thread(.reopen).evaluate(context).isAllowed
        result.canLock = DiscordOperation.thread(.lock).evaluate(context).isAllowed
        result.canUnlock = DiscordOperation.thread(.unlock).evaluate(context).isAllowed
        result.canDelete = DiscordOperation.thread(.delete).evaluate(context).isAllowed
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
        ThreadCapabilities.evaluate(context: capabilityContext(in: thread))
    }

    /// `https://discord.com/channels/<guild>/<thread>`, as Discord's Copy Link.
    nonisolated static func link(guild: Snowflake?, channel: Snowflake) -> String {
        "https://discord.com/channels/\(guild?.description ?? "@me")/\(channel)"
    }
}
