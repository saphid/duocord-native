import Observation
import SwiftUI
import UIKit
import os

/// Light, dark or Onyx (dark with pure black backgrounds for OLED), or
/// following the system.
nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark, onyx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .onyx: "Onyx"
        }
    }

    /// The window style it forces (Onyx is a dark style).
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark, .onyx: .dark
        }
    }
}

nonisolated enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case blurple, purple, fuchsia, green, orange, teal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blurple: "Blurple"
        case .purple: "Purple"
        case .fuchsia: "Fuchsia"
        case .green: "Green"
        case .orange: "Orange"
        case .teal: "Teal"
        }
    }

    var hex: UInt32 {
        switch self {
        case .blurple: 0x5865F2
        case .purple: 0x9B59D0
        case .fuchsia: 0xD6409F
        case .green: 0x248046
        case .orange: 0xD9661A
        case .teal: 0x0E8C9E
        }
    }
}

/// Colours and type, shared by the SwiftUI chrome and the UIKit message list.
/// Dynamic colours follow light and dark mode and read the current theme
/// when they resolve, so a theme change needs only a re-resolve (see
/// `ThemeStore`), never new colour objects.
nonisolated enum Theme {
    struct Choice: Equatable, Sendable {
        var appearance: AppAppearance = .system
        var accent: AccentChoice = .blurple
    }

    private static let state = OSAllocatedUnfairLock(initialState: (choice: Choice(), revision: 0))

    static var choice: Choice { state.withLock { $0.choice } }
    /// Changes with every theme change: caches holding resolved colours key on it.
    static var revision: Int { state.withLock { $0.revision } }

    /// Returns whether anything changed.
    @discardableResult
    static func set(_ choice: Choice) -> Bool {
        state.withLock { state in
            guard state.choice != choice else { return false }
            state.choice = choice
            state.revision &+= 1
            return true
        }
    }

    /// `onyx` replaces the dark value in the Onyx theme (backgrounds go black).
    private static func dynamic(_ dark: UInt32, _ light: UInt32, onyx: UInt32? = nil) -> UIColor {
        let darkColor = UIColor(hex: dark), lightColor = UIColor(hex: light)
        let onyxColor = onyx.map { UIColor(hex: $0) }
        return UIColor { traits in
            usesThemeRevision(traits)
            guard traits.userInterfaceStyle == .dark else { return lightColor }
            if let onyxColor, Theme.choice.appearance == .onyx { return onyxColor }
            return darkColor
        }
    }

    /// UIKit re-resolves a dynamic colour only when a trait its provider read
    /// changes. Reading the revision makes a theme change that keeps the
    /// style (Onyx ↔ Dark, a new accent) re-resolve colours set once, such
    /// as a code card's background.
    private static func usesThemeRevision(_ traits: UITraitCollection) {
        _ = traits[ThemeRevisionTrait.self]
    }

    private static let accents = Dictionary(uniqueKeysWithValues: AccentChoice.allCases.map { ($0, UIColor(hex: $0.hex)) })
    private static func accentColor() -> UIColor { accents[choice.accent] ?? UIColor(hex: 0x5865F2) }

    static let chatBackground = dynamic(0x1A1B1E, 0xFFFFFF, onyx: 0x000000)
    static let sidebarBackground = dynamic(0x141517, 0xF2F3F5, onyx: 0x000000)
    static let railBackground = dynamic(0x0E0F11, 0xE3E5E8, onyx: 0x000000)
    static let elevated = dynamic(0x24262A, 0xF2F3F5, onyx: 0x16171A)
    static let hover = dynamic(0x2A2C31, 0xE8E9EC, onyx: 0x1C1D21)
    static let selected = dynamic(0x34363C, 0xDCDEE2, onyx: 0x26272C)
    static let separator = dynamic(0x2C2E33, 0xE1E2E5, onyx: 0x1E1F23)

    static let textPrimary = dynamic(0xEDEEF0, 0x1D1E21)
    static let textSecondary = dynamic(0xB2B5BC, 0x4E5058)
    static let textMuted = dynamic(0x868A93, 0x6D707A)
    static let link = dynamic(0x5EA6FF, 0x0064D1)

    static let accent = UIColor { traits in
        usesThemeRevision(traits)
        return accentColor()
    }
    static let mentionBackground = dynamic(0x3B3F7A, 0xE1E3FC, onyx: 0x2A2D63)
    static let mentionText = dynamic(0xC9CDFB, 0x3C45C9)
    static let mentionedRowBackground = dynamic(0x2C2A1E, 0xFFF6DD, onyx: 0x1E1C10)
    static let mentionedRowBar = UIColor(hex: 0xF0B232)
    static let codeBackground = dynamic(0x111214, 0xF2F3F5, onyx: 0x0C0C0E)
    static let codeBorder = dynamic(0x24262A, 0xE3E5E8, onyx: 0x1E1F23)
    static let quoteBar = dynamic(0x4E5058, 0xC4C9CE)
    static let spoiler = dynamic(0x0B0C0E, 0x2E3035, onyx: 0x26272C)
    static let unread = UIColor(hex: 0xF23F43)
    static let online = UIColor(hex: 0x23A55A)
    static let idle = UIColor(hex: 0xF0B232)
    static let dnd = UIColor(hex: 0xF23F43)
    static let embedBackground = dynamic(0x202226, 0xF2F3F5, onyx: 0x111214)
    static let reactionBackground = dynamic(0x24262A, 0xF2F3F5, onyx: 0x16171A)
    /// Your own reactions: a wash of the accent colour.
    static let reactionMine = UIColor { traits in
        usesThemeRevision(traits)
        return accentColor().withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.28 : 0.14)
    }
    static let reactionMineBorder = accent

    // MARK: Type (scales with Dynamic Type)

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    static func mono(_ size: CGFloat, style: UIFont.TextStyle = .body) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .regular))
    }

    static var body: UIFont { font(16) }
    static var authorName: UIFont { font(16, .semibold) }
    static var timestamp: UIFont { font(12, style: .caption1) }
    static var small: UIFont { font(13, style: .footnote) }
    static var smallBold: UIFont { font(13, .semibold, style: .footnote) }
}

/// Bumped on every theme change, so UIKit re-resolves dynamic colours and
/// views that bake colours (layers, the message list's render cache) refresh.
nonisolated struct ThemeRevisionTrait: UITraitDefinition {
    static let defaultValue = 0
    static let affectsColorAppearance = true
    static let name = "ThemeRevision"
}

extension UITraitCollection {
    /// Traits that change resolved colours: views that bake colours into
    /// layers re-resolve them when any of these change.
    nonisolated static let colorTraits: [UITrait] = [UITraitUserInterfaceStyle.self, ThemeRevisionTrait.self]
}

/// Applies the theme at runtime: window style, UIKit re-resolve, and a
/// revision SwiftUI views observe through the `Color` palette below.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var choice = Theme.choice
    private(set) var revision = Theme.revision
    @ObservationIgnored private var colors: [ObjectIdentifier: Color] = [:]

    func apply(_ choice: Theme.Choice) {
        Theme.set(choice)
        guard revision != Theme.revision else { return }
        colors = [:]
        self.choice = choice
        revision = Theme.revision
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { style(window) }
        }
    }

    func style(_ window: UIWindow) {
        if window.overrideUserInterfaceStyle != choice.appearance.interfaceStyle {
            window.overrideUserInterfaceStyle = choice.appearance.interfaceStyle
        }
        // Reading an override that was never set throws, so check first.
        if !window.traitOverrides.contains(ThemeRevisionTrait.self) || window.traitOverrides[ThemeRevisionTrait.self] != revision {
            window.traitOverrides[ThemeRevisionTrait.self] = revision
        }
    }

    /// A SwiftUI colour for a theme colour. Reading it registers a dependency
    /// on the revision, and each revision gets a new colour object, so views
    /// redraw with the new theme.
    func color(_ base: UIColor) -> Color {
        _ = revision
        let key = ObjectIdentifier(base)
        if let cached = colors[key] { return cached }
        let color = Color(uiColor: UIColor { base.resolvedColor(with: $0) })
        colors[key] = color
        return color
    }
}

/// Keeps its window's style and theme revision in step with the theme,
/// including windows created after the choice was made.
struct WindowThemer: UIViewRepresentable {
    let revision: Int

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { ThemeStore.shared.style(window) }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        if let window = view.window { ThemeStore.shared.style(window) }
    }
}

extension UIColor {
    nonisolated convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Discord role colours are stored as 0xRRGGBB integers.
    nonisolated static func role(_ value: Int) -> UIColor { UIColor(hex: UInt32(value & 0xFFFFFF)) }
}

extension Color {
    static var chatBackground: Color { ThemeStore.shared.color(Theme.chatBackground) }
    static var sidebarBackground: Color { ThemeStore.shared.color(Theme.sidebarBackground) }
    static var railBackground: Color { ThemeStore.shared.color(Theme.railBackground) }
    static var elevated: Color { ThemeStore.shared.color(Theme.elevated) }
    static var selectedRow: Color { ThemeStore.shared.color(Theme.selected) }
    static var textPrimary: Color { ThemeStore.shared.color(Theme.textPrimary) }
    static var textSecondary: Color { ThemeStore.shared.color(Theme.textSecondary) }
    static var textMuted: Color { ThemeStore.shared.color(Theme.textMuted) }
    static var accentBlurple: Color { ThemeStore.shared.color(Theme.accent) }
    static var unreadRed: Color { ThemeStore.shared.color(Theme.unread) }
    static var separatorLine: Color { ThemeStore.shared.color(Theme.separator) }
    static var codeBackground: Color { ThemeStore.shared.color(Theme.codeBackground) }
    static var reactionBackground: Color { ThemeStore.shared.color(Theme.reactionBackground) }
    static var reactionMine: Color { ThemeStore.shared.color(Theme.reactionMine) }
    nonisolated static func role(_ value: Int) -> Color { Color(uiColor: .role(value)) }
}
