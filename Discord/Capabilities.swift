import Foundation

/// A cached preflight, never a promise that Discord will accept a later write.
nonisolated enum CapabilityState: String, Equatable, Sendable { case allowed, denied, unknown }
nonisolated enum CapabilityFact: String, Equatable, Sendable {
    case account, channel, guild, member, roles, overwrites, parent, membership, threadState, timeout, ownership
    case slowmodeConfiguration, slowmodeHistory, accountKind
}
nonisolated enum AccountCapabilityHypothesis: String, Equatable, Sendable {
    case pinHistory, pinChannelKind, voiceTextConnect, archivedOwnDelete, archivedOwnReactionRemoval
}
nonisolated enum CapabilityReason: Equatable, Sendable {
    case missing(CapabilityFact)
    case missingPermissions(UInt64)
    case unsupportedChannel(ChannelType)
    case privateMembershipRequired, threadArchived, threadLocked, threadActionUnavailable, ownershipRequired
    case timedOut(until: Date), cooldown(until: Date)
    case invalidPayload
    case accountValidationRequired(AccountCapabilityHypothesis)
}
nonisolated enum CapabilityProvenance: String, Equatable, Sendable {
    case directMessage, guildOwner, administrator, roles, overwrites, implicitMask, membership
    case timeout, payload, threadPolicy, slowmode, ownership, cachedFacts, refreshedFacts, accountHypothesis
}
nonisolated struct CapabilityDecision: Equatable, Sendable {
    var state: CapabilityState
    var reasons: [CapabilityReason] = []
    var provenance: [CapabilityProvenance] = []
    var isAllowed: Bool { state == .allowed }

    static func unknown(_ fact: CapabilityFact) -> Self {
        Self(state: .unknown, reasons: [.missing(fact)], provenance: [.cachedFacts])
    }
    static func denied(_ reason: CapabilityReason, _ source: CapabilityProvenance) -> Self {
        Self(state: .denied, reasons: [reason], provenance: [source])
    }
    func combining(_ other: Self) -> Self {
        let state: CapabilityState = self.state == .denied || other.state == .denied ? .denied
            : self.state == .unknown || other.state == .unknown ? .unknown : .allowed
        return Self(state: state, reasons: reasons + other.reasons, provenance: provenance + other.provenance)
    }
}

nonisolated enum ThreadMembership: Equatable, Sendable { case joined, notJoined, unknown }
nonisolated enum CapabilityAccountKind: Equatable, Sendable { case human, bot, unknown }
/// Facts must come from the current account and channel. A channel's latest
/// message or a page without our messages does not establish slowmode eligibility.
nonisolated enum SlowmodeHistory: Equatable, Sendable {
    case unknown, eligible, lastConfirmedSend(Date), cooldownUntil(Date)
}
nonisolated enum SlowmodeEligibility: Equatable, Sendable {
    case notApplicable, exempt, eligible, cooldown(until: Date), unknown(CapabilityFact)
    var decision: CapabilityDecision {
        switch self {
        case .notApplicable, .exempt, .eligible: CapabilityDecision(state: .allowed, provenance: [.slowmode])
        case .cooldown(let date): .denied(.cooldown(until: date), .slowmode)
        case .unknown(let fact): .unknown(fact)
        }
    }
}

nonisolated struct CapabilityContext: Sendable {
    var channel: Channel
    var account: User?
    var guild: Guild?
    var member: Member?
    var parent: Channel?
    var membership: ThreadMembership = .unknown
    var messageAuthorID: Snowflake?
    var accountKind: CapabilityAccountKind = .human
    var slowmodeHistory: SlowmodeHistory = .unknown
    var now = Date()
}

nonisolated struct PermissionResolution: Equatable, Sendable {
    /// Nil is unresolved. Zero means a known absence of permissions.
    var permissions: UInt64?
    /// Before implicit channel and timeout restrictions; useful for exemptions.
    var rawPermissions: UInt64?
    var bypassesOverwrites = false
    var decision: CapabilityDecision

    func requiring(_ bits: UInt64) -> CapabilityDecision {
        guard let permissions else { return decision }
        let missing = bits & ~permissions
        return missing == 0 ? decision : decision.combining(.denied(.missingPermissions(missing), .implicitMask))
    }
}

/// Independent native resolver: guild roles, everyone overwrite, aggregate role
/// overwrites, member overwrite, then implicit channel/thread/timeout masks.
nonisolated enum CapabilityResolver {
    static func permissions(_ context: CapabilityContext) -> PermissionResolution {
        let channel = context.channel
        func unresolved(_ fact: CapabilityFact) -> PermissionResolution {
            PermissionResolution(decision: .unknown(fact))
        }
        guard let account = context.account else { return unresolved(.account) }
        if channel.type.isPrivate {
            guard channel.guildID == nil else { return unresolved(.guild) }
            return PermissionResolution(permissions: Permission.all, rawPermissions: Permission.all,
                                        decision: CapabilityDecision(state: .allowed, provenance: [.directMessage]))
        }
        guard let id = channel.guildID, let guild = context.guild, guild.id == id, !guild.unavailable else { return unresolved(.guild) }
        let source: Channel
        if channel.type.isThread {
            guard let parent = context.parent, parent.id == channel.parentID,
                  parent.guildID == id, !parent.type.isThread, !parent.type.isPrivate else { return unresolved(.parent) }
            source = parent
        } else { source = channel }
        guard let member = context.member, member.userID == account.id else { return unresolved(.member) }
        var bits: UInt64 = 0
        var bypass = false
        var provenance: [CapabilityProvenance] = []
        if guild.ownerID == account.id {
            bits = Permission.all; bypass = true; provenance.append(.guildOwner)
        } else {
            guard member.rolesKnown, guild.roles.contains(where: { $0.id == id }),
                  Set(member.roles).isSubset(of: Set(guild.roles.map(\.id))) else { return unresolved(.roles) }
            for role in guild.roles where role.id == id || member.roles.contains(role.id) {
                guard let flags = UInt64(role.permissions) else { return unresolved(.roles) }
                bits |= flags
            }
            provenance.append(.roles)
            if bits & Permission.administrator != 0 {
                bits = Permission.all; bypass = true; provenance.append(.administrator)
            } else {
                // An omitted overwrite list in a complete channel snapshot means
                // none. Partial CHANNEL_UPDATE merges preserve the previous list.
                let overwrites = source.permissionOverwrites ?? []
                for overwrite in overwrites {
                    guard UInt64(overwrite.allow) != nil, UInt64(overwrite.deny) != nil else { return unresolved(.overwrites) }
                }
                if let everyone = overwrites.first(where: { $0.type == 0 && $0.id == id }) {
                    bits = (bits & ~UInt64(everyone.deny)!) | UInt64(everyone.allow)!
                }
                var allow: UInt64 = 0, deny: UInt64 = 0
                for overwrite in overwrites where overwrite.type == 0 && overwrite.id != id && member.roles.contains(overwrite.id) {
                    allow |= UInt64(overwrite.allow)!; deny |= UInt64(overwrite.deny)!
                }
                bits = (bits & ~deny) | allow
                if let mine = overwrites.first(where: { $0.type == 1 && $0.id == account.id }) {
                    bits = (bits & ~UInt64(mine.deny)!) | UInt64(mine.allow)!
                }
                provenance.append(.overwrites)
            }
        }
        let raw = bits
        // Documented owner/admin exemptions also handle an obsolete timeout
        // stamp left behind after promotion. Effective moderation is computed
        // before private membership, so timeout cannot grant a manager bypass.
        if !bypass, let stamp = member.communicationDisabledUntil {
            guard let until = timeoutDate(stamp) else { return unresolved(.timeout) }
            if until > context.now {
                bits &= Permission.viewChannel | Permission.readHistory
                provenance.append(.timeout)
            }
        }
        if channel.type == .privateThread, channel.ownerID != account.id, bits & Permission.manageThreads == 0 {
            switch context.membership {
            case .unknown: return unresolved(.membership)
            case .notJoined: bits &= ~Permission.viewChannel
            case .joined: break
            }
            provenance.append(.membership)
        }
        let privateDenied = channel.type == .privateThread && bits & Permission.viewChannel == 0
            && context.membership == .notJoined && channel.ownerID != account.id && bits & Permission.manageThreads == 0
        if bits & Permission.viewChannel == 0 { bits &= ~Permission.channelScoped }
        let send = channel.type.isThread ? Permission.sendInThreads : Permission.sendMessages
        if bits & send == 0 { bits &= ~Permission.sendPayload }
        if channel.type.isVoice && bits & Permission.connect == 0 { bits &= ~Permission.voiceScoped }
        provenance.append(.implicitMask)
        return PermissionResolution(permissions: bits, rawPermissions: raw, bypassesOverwrites: bypass,
                                    decision: privateDenied ? CapabilityDecision(state: .denied, reasons: [.privateMembershipRequired], provenance: provenance)
                                        : CapabilityDecision(state: .allowed, provenance: provenance))
    }

    static func timeoutDate(_ stamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
    }

    static func timeout(_ context: CapabilityContext, permissions: PermissionResolution) -> CapabilityDecision {
        if permissions.bypassesOverwrites { return CapabilityDecision(state: .allowed) }
        guard !context.channel.type.isPrivate, let stamp = context.member?.communicationDisabledUntil else {
            return CapabilityDecision(state: .allowed)
        }
        guard let until = timeoutDate(stamp) else { return .unknown(.timeout) }
        return until > context.now ? .denied(.timedOut(until: until), .timeout) : CapabilityDecision(state: .allowed, provenance: [.timeout])
    }

    static func slowmode(_ context: CapabilityContext, permissions: PermissionResolution) -> SlowmodeEligibility {
        if context.channel.type.isPrivate { return .notApplicable }
        guard let bits = permissions.rawPermissions else { return .unknown(.member) }
        if permissions.bypassesOverwrites || bits & (Permission.manageChannels | Permission.manageMessages) != 0 { return .exempt }
        guard let interval = context.channel.rateLimitPerUser else { return .unknown(.slowmodeConfiguration) }
        guard interval >= 0 else { return .unknown(.slowmodeConfiguration) }
        if interval == 0 { return .notApplicable }
        // Never infer that a human is exempt from bot-only observations.
        guard context.accountKind == .human else { return .unknown(.accountKind) }
        switch context.slowmodeHistory {
        case .unknown: return .unknown(.slowmodeHistory)
        case .eligible: return .eligible
        case .lastConfirmedSend(let date):
            let until = date.addingTimeInterval(Double(interval))
            return until > context.now ? .cooldown(until: until) : .eligible
        case .cooldownUntil(let until): return until > context.now ? .cooldown(until: until) : .eligible
        }
    }
}

nonisolated struct MessagePayloadFeatures: Equatable, Sendable {
    var hasText = true
    var isReply = false
    var fileCount = 0
    var hasEmbeds = false
    var hasPoll = false
    var requiredPermissions: UInt64 {
        (isReply ? Permission.readHistory : 0) | (fileCount > 0 ? Permission.attachFiles : 0)
        | (hasEmbeds ? Permission.embedLinks : 0) | (hasPoll ? Permission.sendPolls : 0)
    }
}

nonisolated enum DiscordOperation: Equatable, Sendable {
    case viewChannel, send(MessagePayloadFeatures), editMessage, deleteMessage, addReaction, addExistingReaction, removeOwnReaction
    case listPins, pinMessage, unpinMessage, thread(ThreadAction)

    /// The same physical endpoint used by transport; typed IDs are supplied by
    /// the model adapter. This does not establish permission or message ownership.
    func endpoint(channel: ChannelID, message: MessageID, emoji: String) -> DiscordEndpoint {
        switch self {
        case .viewChannel: .channel(channel)
        case .send: .send(channel)
        case .editMessage: .edit(channel, message)
        case .deleteMessage: .delete(channel, message)
        case .addReaction, .addExistingReaction: .reaction(channel, message, emoji: emoji, add: true)
        case .removeOwnReaction: .reaction(channel, message, emoji: emoji, add: false)
        case .listPins: .pins(channel)
        case .pinMessage: .pin(channel, message, pinned: true)
        case .unpinMessage: .pin(channel, message, pinned: false)
        case .thread(let action):
            switch action {
            case .join: .joinThread(channel)
            case .leave: .leaveThread(channel)
            case .delete: .deleteThread(channel)
            default: .modifyThread(channel)
            }
        }
    }
    /// Representative IDs are used only to project constant method/template
    /// metadata. No request or diagnostic contains these placeholder values.
    private var contractRoute: DiscordRoute {
        endpoint(channel: ChannelID(0), message: MessageID(0), emoji: "").descriptor
    }
    var method: String { contractRoute.method }
    var routeTemplate: String { contractRoute.template }
    func requiredPermissions(in channel: Channel) -> UInt64 {
        let view = Permission.viewChannel
        switch self {
        case .viewChannel, .thread, .editMessage: return view
        case .send(let payload): return view | (channel.type.isThread ? Permission.sendInThreads : Permission.sendMessages) | payload.requiredPermissions
        case .deleteMessage: return view // ownership is evaluated separately
        case .addReaction: return view | Permission.readHistory | Permission.addReactions
        case .addExistingReaction: return view | Permission.readHistory
        case .removeOwnReaction: return view
        case .listPins: return view | Permission.readHistory
        case .pinMessage, .unpinMessage: return view | Permission.pinMessages
        }
    }

    func evaluate(_ context: CapabilityContext) -> CapabilityDecision {
        let channel = context.channel
        let permissions = CapabilityResolver.permissions(context)
        var result = permissions.requiring(requiredPermissions(in: channel))
        if case .viewChannel = self { return result }
        guard channel.type.isTextLike else {
            return result.combining(.denied(.unsupportedChannel(channel.type), .threadPolicy))
        }
        if case .listPins = self { return result }
        let ownDelete = self == .deleteMessage && context.messageAuthorID != nil && context.messageAuthorID == context.account?.id
        let membershipOnly: Bool
        if case .thread(let action) = self { membershipOnly = action == .join || action == .leave }
        else { membershipOnly = false }
        // Own delete and membership-only actions require no permission removed
        // by timeout. An own edit/add reaction is explicitly blocked even though
        // its base access requirements may survive the mask.
        if !ownDelete && self != .removeOwnReaction && !membershipOnly {
            result = result.combining(CapabilityResolver.timeout(context, permissions: permissions))
        }
        if case .thread(let action) = self {
            return result.combining(ThreadCapabilities.decision(action, context: context, permissions: permissions))
        }
        if channel.type.isThread {
            if channel.threadMetadata?.archived == true {
                if ownDelete || self == .removeOwnReaction {
                    // Bot observations of archived deletion do not establish a
                    // human-account prohibition. Preserve the existing explicit
                    // action and expose the hypothesis for later attribution.
                    let hypothesis: AccountCapabilityHypothesis = ownDelete ? .archivedOwnDelete : .archivedOwnReactionRemoval
                    result = result.combining(CapabilityDecision(state: .unknown,
                        reasons: [.accountValidationRequired(hypothesis)], provenance: [.accountHypothesis]))
                } else { result = result.combining(.denied(.threadArchived, .threadPolicy)) }
            }
            if channel.threadMetadata?.locked == true {
                switch self {
                case .send, .pinMessage, .unpinMessage: result = result.combining(.denied(.threadLocked, .threadPolicy))
                default: break
                }
            }
            if channel.threadMetadata?.archived == nil { result = result.combining(.unknown(.threadState)) }
            if case .send = self, channel.threadMetadata?.locked == nil { result = result.combining(.unknown(.threadState)) }
        }
        if channel.type.isVoice, let bits = permissions.permissions, bits & Permission.connect == 0 {
            // Voice/stage text Connect is observed in the bot audit, not yet
            // confirmed for the current human account. Never claim allowed.
            result = result.combining(CapabilityDecision(state: .unknown,
                reasons: [.accountValidationRequired(.voiceTextConnect)], provenance: [.accountHypothesis]))
        }
        switch self {
        case .pinMessage, .unpinMessage:
            // The bot audit suggests an additional history check and kind
            // restrictions. Keep these human-account hypotheses distinguishable
            // from a known missing Pin Messages permission.
            if let bits = permissions.permissions, bits & Permission.readHistory == 0 {
                result = result.combining(CapabilityDecision(state: .unknown,
                    reasons: [.accountValidationRequired(.pinHistory)], provenance: [.accountHypothesis]))
            }
            if channel.type.isVoice {
                result = result.combining(CapabilityDecision(state: .unknown,
                    reasons: [.accountValidationRequired(.pinChannelKind)], provenance: [.accountHypothesis]))
            }
        case .send(let payload):
            if payload.fileCount < 0 || (!payload.hasText && payload.fileCount == 0 && !payload.hasEmbeds && !payload.hasPoll) {
                result = result.combining(.denied(.invalidPayload, .payload))
            }
            result.provenance.append(.payload)
            result = result.combining(CapabilityResolver.slowmode(context, permissions: permissions).decision)
        case .editMessage, .deleteMessage:
            guard let author = context.messageAuthorID, let account = context.account else { return result.combining(.unknown(.ownership)) }
            if author != account.id {
                if case .deleteMessage = self, !channel.type.isPrivate {
                    result = result.combining(permissions.requiring(Permission.manageMessages))
                } else { result = result.combining(.denied(.ownershipRequired, .ownership)) }
            }
        default: break
        }
        return result
    }
}
