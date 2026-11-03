import AppIntents
import SwiftUI

/// The Lock Screen presentation, shared so the app can render it for checks.
struct LockScreenVoiceView: View {
    let state: VoiceActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.live)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.channel).font(.headline).lineLimit(1)
                    if !state.server.isEmpty {
                        Text(state.server).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(startedAt, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 72)
            }
            VoiceControls(state: state)
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

struct VoiceControls: View {
    let state: VoiceActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            // Mute and deafen are toggles: an engaged toggle is filled white
            // with its slashed symbol. Red is reserved for Leave.
            // Fixed labels with a selected fill, like the system call controls.
            toggle(intent: ToggleMuteIntent(), on: state.muted,
                   title: "Mute", symbol: state.muted ? "mic.slash.fill" : "mic.fill")
            toggle(intent: ToggleDeafenIntent(), on: state.deafened,
                   title: "Deafen", symbol: state.deafened ? "headphones.slash" : "headphones")
            Button(intent: DisconnectVoiceIntent()) {
                Label("Leave", systemImage: "phone.down.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .tint(Palette.leave)
        }
        .buttonStyle(.borderedProminent)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private func toggle(intent: some LiveActivityIntent, on: Bool, title: String, symbol: String) -> some View {
        Button(intent: intent) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(on ? Color.black : Color.white)
        }
        .tint(on ? .white : Color(white: 0.32))
        .accessibilityValue(on ? "On" : "Off")
    }
}

enum Palette {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let live = Color(red: 0.14, green: 0.79, blue: 0.43)
    static let muted = Color(red: 0.93, green: 0.26, blue: 0.27)
    static let leave = Color(red: 0.85, green: 0.22, blue: 0.24)
}

/// Waveform, channel and server: the expanded Dynamic Island's leading region.
struct VoiceHeadline: View {
    let state: VoiceActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").font(.headline).foregroundStyle(Palette.live)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.channel).font(.headline).lineLimit(1)
                if !state.server.isEmpty {
                    Text(state.server).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
