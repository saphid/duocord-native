import Foundation
import Observation

/// Editing state belongs to the conversation, not a particular SwiftUI or
/// UIKit instance. A new native field takes over the old field's lease so
/// late teardown callbacks cannot dismiss it or overwrite its caret.
@MainActor @Observable
final class ComposerContinuity {
    private(set) var focusedChannel: Snowflake?
    private(set) var focusRevision: UInt64 = 0
    private var selections: [Snowflake: Selection] = [:]
    @ObservationIgnored private var owners: [Snowflake: UUID] = [:]

    private struct Selection {
        let text: String
        let range: NSRange
    }

    func attach(in channel: Snowflake) -> UUID {
        let owner = UUID()
        owners[channel] = owner
        return owner
    }

    func owns(_ owner: UUID, in channel: Snowflake) -> Bool { owners[channel] == owner }

    func detach(_ owner: UUID, in channel: Snowflake) {
        if owns(owner, in: channel) { owners[channel] = nil }
        // Removing a field during reconstruction is not a keyboard dismissal.
    }

    func requestFocus(in channel: Snowflake) {
        focusRevision &+= 1
        focusedChannel = channel
    }

    func shouldFocus(_ owner: UUID, in channel: Snowflake, selectedChannel: Snowflake?) -> Bool {
        owns(owner, in: channel) && focusedChannel == channel && selectedChannel == channel
    }

    func beganEditing(_ owner: UUID, in channel: Snowflake, selectedChannel: Snowflake?) {
        guard owns(owner, in: channel), selectedChannel == channel else { return }
        requestFocus(in: channel)
    }

    /// Called after UIKit's end-editing callback has unwound. Detached and
    /// replaced fields retain intent; a still-attached field records dismissal.
    func endedEditing(_ owner: UUID, in channel: Snowflake, isAttached: Bool, revision: UInt64? = nil) {
        guard owns(owner, in: channel), isAttached, focusedChannel == channel else { return }
        if let revision, revision != focusRevision { return }
        focusedChannel = nil
    }

    func conversationChanged() { focusedChannel = nil }

    func selection(in channel: Snowflake, text: String) -> NSRange {
        guard let saved = selections[channel], saved.text.utf16.elementsEqual(text.utf16),
              Self.isValid(saved.range, in: text) else {
            return NSRange(location: text.utf16.count, length: 0)
        }
        return saved.range
    }

    func saveSelection(_ range: NSRange, text: String, in channel: Snowflake, owner: UUID? = nil) {
        if let owner, !owns(owner, in: channel) { return }
        guard Self.isValid(range, in: text) else { return }
        if let saved = selections[channel], saved.text.utf16.elementsEqual(text.utf16), saved.range == range { return }
        selections[channel] = Selection(text: text, range: range)
    }

    private static func isValid(_ range: NSRange, in text: String) -> Bool {
        let units = text.utf16
        guard range.location >= 0, range.length >= 0, range.location <= units.count,
              range.length <= units.count - range.location else { return false }
        // Foundation can construct String.Index values inside a surrogate
        // pair. Such a caret cannot be restored safely in a new native field.
        for offset in [range.location, range.location + range.length] where offset < units.count {
            let unit = units[units.index(units.startIndex, offsetBy: offset)]
            if (0xDC00...0xDFFF).contains(unit) { return false }
        }
        return Range(range, in: text) != nil
    }

    func reset() {
        focusedChannel = nil
        selections = [:]
        owners = [:]
    }
}
