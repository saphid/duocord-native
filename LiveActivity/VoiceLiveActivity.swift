import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DuocordWidgets: WidgetBundle {
    var body: some Widget {
        VoiceLiveActivity()
    }
}

/// Shown while you're connected to a Discord voice channel.
struct VoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            LockScreenVoiceView(state: context.state, startedAt: context.attributes.startedAt)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VoiceHeadline(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 64, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VoiceControls(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(Palette.live)
            } compactTrailing: {
                Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(context.state.muted ? Palette.muted : .white)
            } minimal: {
                Image(systemName: context.state.muted ? "mic.slash.fill" : "waveform")
                    .foregroundStyle(context.state.muted ? Palette.muted : Palette.live)
            }
            .keylineTint(Palette.live)
        }
    }
}

