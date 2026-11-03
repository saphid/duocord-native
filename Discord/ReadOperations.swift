import Foundation

/// Standalone manual acks accept zero as the never-read boundary. Bulk acks
/// require a positive message ID. Never derive a predecessor by subtracting an ID.
nonisolated struct ReadAcknowledgement: Equatable, Sendable {
    var channel: Snowflake
    var message: Snowflake
    var manual = false
    var mentionCount: Int? = nil

    var fields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["token": .null]
        if manual { fields["manual"] = .bool(true) }
        if let mentionCount { fields["mention_count"] = .number(Double(mentionCount)) }
        return fields
    }
    var bulkFields: JSONValue {
        .object(["channel_id": .string(channel.description), "message_id": .string(message.description),
                 "read_state_type": .number(0)])
    }
}

nonisolated struct ReadVersion: Equatable, Sendable {
    var boundary = 0
    var mentions = 0
    /// Only message arrivals advance this counter; other count authority does not.
    var mentionArrivals = 0
}

nonisolated struct ReadEchoRecord: Sendable {
    var read: ReadAcknowledgement
    var intent: UUID
    var sequence: Int
    var releasesHold: Bool
    var capturedVersion: ReadVersion
    var superseded = false
    var seen = false
    var version: Int?
}
