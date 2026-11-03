import SwiftUI

/// A remote image through the shared pipeline (downsampled, cached).
struct RemoteImage: View {
    let url: URL?
    let size: CGSize
    var contentMode: ContentMode = .fill
    var placeholder: Color = .elevated
    var mediaKind: MediaKind = .image
    @State private var visible = false
    @State private var playbackToggle = 0

    var body: some View {
        ZStack {
            placeholder
            RemoteImageSurface(url: url, size: size, mode: contentMode, kind: mediaKind, visible: visible, toggle: playbackToggle)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityActions {
            if mediaKind == .emoji {
                Button("Play or pause animation") { playbackToggle += 1 }
            }
        }
    }
}

private struct RemoteImageSurface: UIViewRepresentable {
    let url: URL?
    let size: CGSize
    let mode: ContentMode
    let kind: MediaKind
    let visible: Bool
    let toggle: Int
    final class Coordinator { var toggle = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> RemoteImageView { RemoteImageView() }
    func updateUIView(_ view: RemoteImageView, context: Context) {
        view.contentMode = mode == .fit ? .scaleAspectFit : .scaleAspectFill
        view.clipsToBounds = true
        view.playbackEnabled = visible
        view.setImage(url, size: size, kind: kind)
        if context.coordinator.toggle != toggle {
            context.coordinator.toggle = toggle
            view.togglePlayback()
        }
    }
    static func dismantleUIView(_ view: RemoteImageView, coordinator: Coordinator) {
        view.playbackEnabled = false
        view.setImage(nil, size: .zero)
    }
}

struct AvatarView: View {
    let user: User?
    var size: CGFloat

    var body: some View {
        RemoteImage(url: user?.avatarURL(size: Int(size * 3)), size: CGSize(width: size, height: size), mediaKind: .avatar)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

struct ChannelAvatar: View {
    @Environment(DiscordStore.self) private var store
    let channel: Channel
    var size: CGFloat

    var body: some View {
        if channel.type == .groupDM {
            ZStack {
                Circle().fill(Color.accentBlurple.opacity(0.8))
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            AvatarView(user: store.recipients(of: channel).first, size: size)
        }
    }
}

struct PresenceDot: View {
    let status: PresenceStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.sidebarBackground, lineWidth: 2.5))
            .accessibilityLabel(status.rawValue)
    }

    private var color: Color {
        switch status {
        case .online: Color(uiColor: Theme.online)
        case .idle: Color(uiColor: Theme.idle)
        case .dnd: Color(uiColor: Theme.dnd)
        default: Color.textMuted
        }
    }
}

/// Bottom controls (composer, account row) with no keyboard up. The system
/// bottom inset on iPhone (34 pt, iPhone Duo included) also covers the
/// display's corners; the home indicator itself needs 20 pt, the whole
/// inset of a home-indicator iPad. The controls drop into the difference;
/// with a keyboard up they stay on it.
struct HomeIndicatorClearance: ViewModifier {
    static let clearance: CGFloat = 20
    @Environment(AppModel.self) private var model
    @State private var windowInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, model.keyboardVisible ? 0 : -max(0, windowInset - Self.clearance))
            .background { WindowInsetReader(bottom: $windowInset).allowsHitTesting(false) }
    }
}

extension View {
    func homeIndicatorClearance() -> some View { modifier(HomeIndicatorClearance()) }
}

/// The window's own bottom inset (home indicator and corners), which a
/// keyboard never changes.
private struct WindowInsetReader: UIViewRepresentable {
    @Binding var bottom: CGFloat

    func makeUIView(context: Context) -> Reader {
        let view = Reader()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Reader, context: Context) {
        let binding = $bottom
        view.report = { value in if binding.wrappedValue != value { binding.wrappedValue = value } }
        view.setNeedsLayout()
    }

    final class Reader: UIView {
        var report: ((CGFloat) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); update() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); update() }
        override func layoutSubviews() { super.layoutSubviews(); update() }

        private func update() {
            guard let window else { return }
            let value = window.safeAreaInsets.bottom
            // Never during SwiftUI's own update pass.
            DispatchQueue.main.async { [weak self] in self?.report?(value) }
        }
    }
}
