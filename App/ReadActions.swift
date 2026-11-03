import Foundation

/// Deletions are retained only for the lifetime of an outstanding operation.
nonisolated struct UnreadTargetOperation {
    var channel: Snowflake
    var deleted: Set<Snowflake> = []
    var successors: [Snowflake: Snowflake] = [:]

    func surviving(_ target: Snowflake) -> Snowflake? {
        var candidate = target
        while deleted.contains(candidate) {
            guard let next = successors[candidate], next > candidate else { return nil }
            candidate = next
        }
        return candidate
    }
}

extension AppModel {
    var allowsReadWrites: Bool {
        #if DEBUG
        isMock && api is MockDiscord
        #else
        true
        #endif
    }

    /// Explicit taps ignore the automatic-ack preference. DEBUG real sessions
    /// reject the operation before any history read or local success is applied.
    @discardableResult
    func markAsRead(channel: Snowflake) -> Task<Void, Never> {
        let reads = eligibleReadChannels.filter { $0.id == channel }.compactMap(capturedRead)
        return enqueueRead(reads)
    }

    /// Mark as Read from an alert acknowledges only through the notified
    /// message, or the known latest if lower, so newer messages stay unread.
    /// Nil (no write) when already read there or no latest ID is known.
    func markAsRead(channel: Snowflake, through message: Snowflake) -> Task<Void, Never>? {
        guard message > 0, let info = eligibleReadChannels.first(where: { $0.id == channel }),
              let latest = info.lastMessageID, latest > 0 else { return nil }
        let boundary = min(message, latest)
        guard boundary > (store.readBoundary(info) ?? 0) else { return nil }
        // Capture partialness before waiting in the FIFO. A later plain
        // arrival cannot turn a full read into a partial one.
        return enqueueRead([ReadAcknowledgement(channel: channel, message: boundary)], cancellationSensitive: true,
                           preservingMentions: boundary < latest)
    }

    @discardableResult
    func markServerAsRead(_ guild: Snowflake) -> Task<Void, Never> {
        enqueueRead(eligibleReadChannels.filter { $0.guildID == guild }.compactMap(capturedRead), bulk: true)
    }

    @discardableResult
    func markAllAsRead() -> Task<Void, Never> {
        // Full eligible set; Inbox's presentation prefix is deliberately irrelevant.
        enqueueRead(eligibleReadChannels.compactMap(capturedRead), bulk: true)
    }

    var eligibleReadChannels: [Channel] {
        store.channels.values.filter {
            ($0.type.isTextLike || $0.type.isForumLike) && ($0.guildID == nil || store.canView($0))
                && ($0.type != .privateThread || store.joinedThreads.contains($0.id) || $0.ownerID == store.me?.id
                    || store.permissions(in: $0) & Permission.manageThreads != 0)
        }.sorted { $0.id < $1.id }
    }

    private func capturedRead(_ channel: Channel) -> ReadAcknowledgement? {
        // Missing latest IDs cannot be safely acknowledged. Empty channels are no-ops.
        guard let latest = channel.lastMessageID, latest > 0,
              latest >= (store.readStates[channel.id]?.lastMessageID ?? 0) else { return nil }
        return ReadAcknowledgement(channel: channel.id, message: latest)
    }

    @discardableResult
    func markUnread(_ message: Message) -> Task<Void, Never> {
        guard eligibleReadChannels.contains(where: { $0.id == message.channelID && $0.lastMessageID != nil }) else { return Task {} }
        return enqueueRead([ReadAcknowledgement(channel: message.channelID, message: message.id, manual: true)], unread: message)
    }

    /// One FIFO for all read writes includes overlapping channel/server/all
    /// operations. Captured IDs stay fixed while queued. Confirmed write order
    /// and gateway field versions protect newer authority; intents own feedback.
    @discardableResult
    func enqueueRead(_ reads: [ReadAcknowledgement], bulk: Bool = false,
                     unread: Message? = nil, automatic: Bool = false, cancellationSensitive: Bool = false,
                     preservingMentions: Bool = false) -> Task<Void, Never> {
        guard !reads.isEmpty else { return Task {} }
        guard allowsReadWrites else {
            for read in reads { readErrors[read.channel] = "Read actions are disabled for real accounts in Debug." }
            showError("Read actions are disabled for real accounts in Debug.")
            return Task {}
        }
        let intent = UUID(), session = readSession, epoch = store.readEpoch, visit = conversationVisit
        let previous = readQueue, api = api
        let capturedVersions = Dictionary(uniqueKeysWithValues: reads.map { ($0.channel, store.readVersion($0.channel)) })
        if let unread { unreadTargetOperations[intent] = UnreadTargetOperation(channel: unread.channelID) }
        for read in reads {
            cancelAutomaticAck(read.channel)
            store.pendingReadChannels.insert(read.channel)
            store.readIntents[read.channel] = intent
            readSaves[read.channel, default: 0] += 1
            readErrors[read.channel] = nil
            if unread != nil { store.pendingUnreadChannels.insert(read.channel) }
        }
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.unreadTargetOperations[intent] = nil }
            guard self.readSession == session, self.store.readEpoch == epoch else { return }
            var resolved = reads
            defer {
                if self.readSession == session, self.store.readEpoch == epoch {
                    for read in reads {
                        self.readSaves[read.channel, default: 1] -= 1
                        if self.readSaves[read.channel] == 0 { self.store.pendingReadChannels.remove(read.channel) }
                        if self.store.readIntents[read.channel] == intent { self.store.pendingUnreadChannels.remove(read.channel) }
                    }
                }
            }
            // Alert actions may be cancelled while queued behind another read.
            // Keep ordinary reader and explicit UI actions' existing lifetime.
            guard !cancellationSensitive || !Task.isCancelled else { return }
            if automatic {
                // A debounce that entered the FIFO is still disposable work.
                // Do not adopt newer authority after waiting behind another channel.
                guard self.allowsReadWrites, self.settings.markReadOnServer, self.isActive,
                      self.conversationVisit == visit,
                      reads.allSatisfy({ read in
                          self.selectedChannel == read.channel &&
                          self.store.readVersion(read.channel) == capturedVersions[read.channel] &&
                          self.store.readIntents[read.channel] == intent &&
                          !self.store.manualUnreadChannels.contains(read.channel) &&
                          !self.store.pendingUnreadChannels.contains(read.channel) &&
                          (self.automaticReadCeilings[read.channel].map { read.message <= $0 } ?? true)
                      }) else { return }
            }
            do {
                if let unread {
                    // Even adjacent cached rows may straddle a seeded/around-page
                    // gap. Ask for the actual predecessor, never synthesize an ID.
                    let before = try await api.messages(channel: unread.channelID, before: unread.id, after: nil, around: nil, limit: 1)
                    let predecessor = before.filter { $0.id < unread.id }.max { $0.id < $1.id }?.id ?? 0
                    resolved[0].message = predecessor
                    // Exact count only when the contiguous loaded suffix reaches
                    // latest. Otherwise retain the server's count (omit the field).
                    if let timeline = self.messages.existingTimeline(for: unread.channelID),
                       timeline.isAtLatest, !timeline.isSeeded, timeline.index(of: unread.id) != nil,
                       timeline.messages.last?.id == self.store.channel(unread.channelID)?.lastMessageID {
                        resolved[0].mentionCount = timeline.messages.filter { $0.id >= unread.id && self.store.mentionsMe($0) }.count
                    }
                }
                guard self.readSession == session, self.store.readEpoch == epoch else { return }
                let versions = Dictionary(uniqueKeysWithValues: resolved.map { read in
                    var version = self.store.readVersion(read.channel)
                    if !read.manual { version.mentions = capturedVersions[read.channel]!.mentions }
                    return (read.channel, version)
                })
                for read in resolved { self.store.registerReadEcho(read, intent: intent, releasesHold: !automatic && !read.manual) }
                if bulk { try await api.acknowledgeBulk(resolved) }
                else { for read in resolved { try await api.acknowledge(read) } }
                guard self.readSession == session, self.store.readEpoch == epoch else { return }
                for read in resolved {
                    if self.store.applyRead(read, version: versions[read.channel]!, intent: intent, preservingMentions: preservingMentions) {
                        self.recordReadPresentation(read, target: unread.flatMap { self.unreadTargetOperations[intent]?.surviving($0.id) },
                                                    automatic: automatic, visit: visit)
                    }
                    if self.store.readIntents[read.channel] == intent { self.readErrors[read.channel] = nil }
                }
                self.updateBadge()
            } catch {
                guard self.readSession == session, self.store.readEpoch == epoch else { return }
                for read in resolved where self.store.readIntents[read.channel] == intent {
                    // A gateway echo remains authoritative when the HTTP
                    // response is lost. Apply presentation only for that echo.
                    if self.store.readWasEchoed(read.channel, intent: intent) {
                        self.recordReadPresentation(read, target: unread.flatMap { self.unreadTargetOperations[intent]?.surviving($0.id) },
                                                    automatic: automatic, visit: visit)
                    }
                    self.readErrors[read.channel] = error.localizedDescription
                }
                self.showError("Couldn’t update read state. " + error.localizedDescription)
            }
        }
        readQueue = task
        return task
    }

    private func recordReadPresentation(_ read: ReadAcknowledgement, target: Snowflake?, automatic: Bool, visit: UUID) {
        if read.manual, store.manualUnreadChannels.contains(read.channel), store.readStates[read.channel]?.lastMessageID == read.message {
            // Leaving, including a round trip during the request, ends the hold.
            if selectedChannel != read.channel || conversationVisit != visit { store.resumeAutomaticReading(read.channel) }
            unreadMarkers[read.channel] = read.message
            unreadTargets[read.channel] = target
        } else if !automatic, !read.manual, !store.manualUnreadChannels.contains(read.channel),
                  (store.readStates[read.channel]?.lastMessageID ?? 0) >= read.message {
            // Layout callbacks are not fresh reading intent. Preserve arrivals
            // beyond the captured boundary until a deliberate reader move.
            if (store.channel(read.channel)?.lastMessageID ?? 0) > read.message {
                automaticReadCeilings[read.channel] = read.message
            } else { automaticReadCeilings[read.channel] = nil }
            unreadMarkers[read.channel] = nil
            unreadTargets[read.channel] = nil
        }
    }

    func cancelReadOperations() {
        notifications.resetReadSession()
        unreadTargetOperations = [:]
        unreadTargets = [:]; automaticReadCeilings = [:]
        readSession = UUID()
        readQueue?.cancel(); readQueue = nil
        readSaves = [:]; readErrors = [:]; firstVisibleMessages = [:]
    }

    func unreadBoundary(for channel: Snowflake) -> Snowflake? {
        if store.manualUnreadChannels.contains(channel) { return store.readStates[channel]?.lastMessageID ?? 0 }
        if let marker = unreadMarkers[channel] { return marker }
        if let info = store.channel(channel), store.isUnread(info) { return store.readBoundary(info) }
        return nil
    }

    func explicitUnreadTarget(for channel: Snowflake) -> Snowflake? {
        guard unreadMarkers[channel] == unreadBoundary(for: channel) else { return nil }
        return unreadTargets[channel]
    }

    func unreadTargetDeleted(channel: Snowflake, ids: Set<Snowflake>) {
        // Called before timeline removal. Successors in this loaded, unseeded
        // window are contiguous even when the predecessor lies outside it.
        var successors: [Snowflake: Snowflake] = [:]
        if let timeline = messages.existingTimeline(for: channel), !timeline.isSeeded {
            var next: Snowflake?
            for message in timeline.messages.reversed() where timeline.sendState(for: message) == nil {
                if ids.contains(message.id) {
                    if let next, !timeline.hasUnresolvedDeletion(after: message.id, before: next, excluding: ids) {
                        successors[message.id] = next
                    }
                } else { next = message.id }
            }
        }
        if let target = unreadTargets[channel], ids.contains(target) { unreadTargets[channel] = successors[target] }
        for token in Array(unreadTargetOperations.keys) {
            guard var operation = unreadTargetOperations[token], operation.channel == channel else { continue }
            operation.deleted.formUnion(ids)
            operation.successors.merge(successors, uniquingKeysWith: { _, new in new })
            unreadTargetOperations[token] = operation
        }
    }

    func unreadIsAboveViewport(_ channel: Snowflake) -> Bool {
        guard let info = store.channel(channel), store.isUnread(info),
              let boundary = unreadBoundary(for: channel), let first = firstVisibleMessages[channel] else { return false }
        if let target = explicitUnreadTarget(for: channel) { return target < first }
        if let timeline = messages.existingTimeline(for: channel),
           let target = timeline.messages.first(where: { $0.id > boundary }),
           (!timeline.hasMoreBefore || timeline.messages.contains(where: { $0.id == boundary })) {
            return target.id < first
        }
        return boundary < first // boundary precedes this incomplete cached window
    }

    @discardableResult
    func jumpToUnread(_ channel: Snowflake) -> Task<Void, Never> {
        let boundary = unreadBoundary(for: channel), epoch = store.readEpoch
        guard let boundary else { return Task {} }
        let operation = UUID()
        unreadTargetOperations[operation] = UnreadTargetOperation(channel: channel)
        return Task { [weak self] in
            guard let self else { return }
            defer { self.unreadTargetOperations[operation] = nil }
            do {
                // after+limit=1 yields the first unread even outside the cached
                // window. Existing reveal/history code opens around that actual ID.
                let page = try await self.api.messages(channel: channel, before: nil, after: boundary, around: nil, limit: 1)
                guard self.selectedChannel == channel, self.store.readEpoch == epoch,
                      self.unreadBoundary(for: channel) == boundary else { return }
                if let first = page.filter({ $0.id > boundary }).min(by: { $0.id < $1.id }),
                   let target = self.unreadTargetOperations[operation]?.surviving(first.id) {
                    self.unreadMarkers[channel] = boundary
                    self.unreadTargets[channel] = target
                    self.revealRequest = (channel, target, UUID())
                }
            } catch { self.showError("Couldn’t find the first unread message. " + error.localizedDescription) }
        }
    }
}
