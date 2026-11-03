import ActivityKit
import Foundation

/// Starts, updates and ends the voice Live Activity from the call state the
/// gateway reports, and keeps it consistent with that state and the setting.
final class VoiceActivityController {
    private var activity: Activity<VoiceActivityAttributes>?
    private var shownState: VoiceActivityAttributes.ContentState?
    /// The page's latest report, kept so a settings change or a failed start
    /// can be reconciled without waiting for the call to change.
    private var connected = false
    private var latest: VoiceActivityAttributes.ContentState?

    init() {
        // A relaunch drops the voice engine and any call; activities left
        // by a previous process describe nothing and are ended.
        for stale in Activity<VoiceActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(connected: Bool, state: VoiceActivityAttributes.ContentState, enabled: Bool) {
        self.connected = connected
        latest = connected ? state : nil
        reconcile(enabled: enabled)
    }

    func reconcile(enabled: Bool) {
        guard enabled, connected, let state = latest else {
            endActivity()
            return
        }
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            guard state != shownState else { return }
            shownState = state
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled,
                  let started = try? Activity.request(attributes: VoiceActivityAttributes(startedAt: .now),
                                                      content: content, pushType: nil) {
            activity = started
            shownState = state
        }
    }

    /// Ends the activity; for sign-out and reloads, where the page won't
    /// report the call ending.
    func end() {
        connected = false
        latest = nil
        endActivity()
    }

    private func endActivity() {
        shownState = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
