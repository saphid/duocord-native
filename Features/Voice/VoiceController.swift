import ActivityKit
import Foundation
import Observation

/// The call as the native UI sees it. Truth comes from the gateway's
/// VOICE_STATE_UPDATE for this account; the engine only carries media.
@Observable
final class VoiceController {
    struct Call: Equatable {
        var guildID: Snowflake
        var channelID: Snowflake
        var startedAt: Date
    }

    weak var model: AppModel?
    private(set) var call: Call?
    private(set) var joining: Snowflake?
    private(set) var error: String?
    @ObservationIgnored private var engine: VoiceEngine?
    @ObservationIgnored private let activity = VoiceActivityController()

    /// Debug builds only join Alex's own test channel (duocord-test).
    static let debugAllowedChannel: Snowflake = 1565909273286942760

    init() {
        VoiceControl.handler = { [weak self] action in
            switch action {
            case .mute: self?.toggleMute()
            case .deafen: self?.toggleDeafen()
            case .disconnect: self?.leave()
            }
        }
    }

    var isMuted: Bool { model?.store.myVoiceState?.selfMute ?? false }
    var isDeafened: Bool { model?.store.myVoiceState?.selfDeaf ?? false }

    func canJoin(_ channel: Channel) -> Bool {
        guard model?.store.contentAccess(to: channel).permitsContent == true else { return false }
        #if DEBUG
        return channel.id == Self.debugAllowedChannel
        #else
        return true
        #endif
    }

    func join(_ channel: Channel) {
        guard let model, let guild = channel.guildID, let credentials = model.credentials, canJoin(channel) else {
            error = "Voice in debug builds is limited to the test channel."
            return
        }
        error = nil
        joining = channel.id
        let engine = self.engine ?? VoiceEngine(credentials: credentials)
        engine.onFailure = { [weak self] message in
            self?.error = message
            self?.joining = nil
        }
        self.engine = engine
        model.keepAlive.stop()
        engine.join(guild: guild, channel: channel.id)
    }

    func toggleMute() { engine?.toggleMute() }
    func toggleDeafen() { engine?.toggleDeafen() }

    func leave() {
        engine?.leave()
        engine = nil
        joining = nil
        if call != nil {
            call = nil
            activity.end()
        }
        model?.reconcileKeepAlive()
    }

    /// Called on every VOICE_STATE_UPDATE.
    func stateChanged() {
        guard let model else { return }
        let state = model.store.myVoiceState
        if let state, let channel = state.channelID, let guild = state.guildID, engine != nil {
            if call?.channelID != channel { call = Call(guildID: guild, channelID: channel, startedAt: .now) }
            joining = nil
        } else if state == nil, call != nil {
            // Disconnected elsewhere (kicked, moved, other device).
            call = nil
            engine?.tearDown()
            engine = nil
            model.reconcileKeepAlive()
        }
        updateActivity()
    }

    func updateActivity() {
        guard let model, let call else {
            activity.end()
            return
        }
        let channel = model.store.channel(call.channelID)?.name ?? "Voice"
        let server = model.store.guilds[call.guildID]?.name ?? ""
        activity.update(connected: true,
                        state: .init(channel: channel, server: server, muted: isMuted, deafened: isDeafened),
                        enabled: model.settings.liveActivity)
        Perf.shared.record("liveActivity", ["running": Activity<VoiceActivityAttributes>.activities.count,
                                            "muted": isMuted, "deafened": isDeafened,
                                            "enabled": ActivityAuthorizationInfo().areActivitiesEnabled])
    }
}
