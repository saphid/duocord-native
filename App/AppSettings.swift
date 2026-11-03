import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var acknowledgedRisk: Bool { didSet { defaults.set(acknowledgedRisk, forKey: "acknowledgedRisk") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var badgeEnabled: Bool { didSet { defaults.set(badgeEnabled, forKey: "badgeEnabled") } }
    var keepAlive: Bool { didSet { defaults.set(keepAlive, forKey: "keepAlive") } }
    var liveActivity: Bool { didSet { defaults.set(liveActivity, forKey: "liveActivity") } }
    /// Tell Discord which messages you've read (as the official app does).
    var markReadOnServer: Bool { didSet { defaults.set(markReadOnServer, forKey: "markReadOnServer") } }
    var sendTypingIndicator: Bool { didSet { defaults.set(sendTypingIndicator, forKey: "sendTypingIndicator") } }
    /// Book pose: the server and channel list ends at the fold.
    var followFold: Bool { didSet { defaults.set(followFold, forKey: "followFold") } }
    var compactMessages: Bool { didSet { defaults.set(compactMessages, forKey: "compactMessages") } }
    var autoplayGIFs: Bool { didSet { defaults.set(autoplayGIFs, forKey: "autoplayGIFs"); mediaPreferencesChanged() } }
    var animateEmoji: Bool { didSet { defaults.set(animateEmoji, forKey: "animateEmoji"); mediaPreferencesChanged() } }
    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance"); applyTheme() }
    }
    var accent: AccentChoice {
        didSet { defaults.set(accent.rawValue, forKey: "accent"); applyTheme() }
    }
    /// Emoji you reacted with most recently, newest first.
    private(set) var recentEmoji: [Emoji] {
        didSet { defaults.set(try? JSONEncoder().encode(recentEmoji), forKey: "recentEmoji") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        let debugDefaults = false
        #else
        let debugDefaults = true
        #endif
        defaults.register(defaults: [
            "notificationsEnabled": true,
            "badgeEnabled": true,
            "keepAlive": true,
            "liveActivity": true,
            // Debug builds never touch read state on the real account.
            "markReadOnServer": debugDefaults,
            "sendTypingIndicator": true,
            "followFold": true,
            "compactMessages": false,
            "autoplayGIFs": true,
            "animateEmoji": true,
        ])
        acknowledgedRisk = defaults.bool(forKey: "acknowledgedRisk")
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        badgeEnabled = defaults.bool(forKey: "badgeEnabled")
        keepAlive = defaults.bool(forKey: "keepAlive")
        liveActivity = defaults.bool(forKey: "liveActivity")
        #if DEBUG
        // Debug builds never touch read state on the real account, whatever was saved.
        markReadOnServer = false
        #else
        markReadOnServer = defaults.bool(forKey: "markReadOnServer")
        #endif
        sendTypingIndicator = defaults.bool(forKey: "sendTypingIndicator")
        followFold = defaults.bool(forKey: "followFold")
        compactMessages = defaults.bool(forKey: "compactMessages")
        autoplayGIFs = defaults.bool(forKey: "autoplayGIFs")
        animateEmoji = defaults.bool(forKey: "animateEmoji")
        appearance = defaults.string(forKey: "appearance").flatMap(AppAppearance.init) ?? .system
        accent = defaults.string(forKey: "accent").flatMap(AccentChoice.init) ?? .blurple
        recentEmoji = defaults.data(forKey: "recentEmoji").flatMap { try? JSONDecoder().decode([Emoji].self, from: $0) } ?? []
        applyTheme()
    }

    private func applyTheme() {
        ThemeStore.shared.apply(Theme.Choice(appearance: appearance, accent: accent))
    }

    private func mediaPreferencesChanged() {
        NotificationCenter.default.post(name: .mediaPlaybackPreferencesChanged, object: defaults)
    }

    func noteRecent(_ emoji: Emoji) {
        var list = recentEmoji.filter { $0.reactionKey != emoji.reactionKey }
        list.insert(emoji, at: 0)
        recentEmoji = Array(list.prefix(24))
    }
}
