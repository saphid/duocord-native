import ActivityKit
import AppIntents
import Foundation

/// The voice-call Live Activity, shared by the app and its widget extension.
nonisolated struct VoiceActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var channel: String
        var server: String
        var muted: Bool
        var deafened: Bool
    }

    var startedAt: Date
}

/// Routes Live Activity buttons to the app, which owns the voice engine.
/// LiveActivityIntents run in the app's process, where `handler` is set.
enum VoiceControl {
    enum Action: Sendable { case mute, deafen, disconnect }

    @MainActor static var handler: ((Action) -> Void)?

    static func perform(_ action: Action) async {
        await MainActor.run { handler?(action) }
    }
}

struct ToggleMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Mute"
    func perform() async throws -> some IntentResult {
        await VoiceControl.perform(.mute)
        return .result()
    }
}

struct ToggleDeafenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Deafen"
    func perform() async throws -> some IntentResult {
        await VoiceControl.perform(.deafen)
        return .result()
    }
}

struct DisconnectVoiceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Disconnect"
    func perform() async throws -> some IntentResult {
        await VoiceControl.perform(.disconnect)
        return .result()
    }
}
