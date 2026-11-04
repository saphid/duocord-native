import UIKit

protocol MessageCellDelegate: AnyObject {
    func messageCell(_ cell: MessageCell, open media: MediaItem, from view: UIView)
    func messageCell(_ cell: MessageCell, tap: RichTextView.Tap)
    func messageCell(_ cell: MessageCell, toggleReaction emoji: Emoji, on message: Snowflake)
    func messageCell(_ cell: MessageCell, showReactions emoji: Emoji, on message: Snowflake)
    func messageCell(_ cell: MessageCell, addReactionTo message: Snowflake)
    func messageCell(_ cell: MessageCell, jumpTo message: Snowflake)
    func messageCell(_ cell: MessageCell, openUser user: Snowflake)
    func messageCell(_ cell: MessageCell, retry message: Snowflake)
    func messageCell(_ cell: MessageCell, discard message: Snowflake)
    func messageCell(_ cell: MessageCell, revealBlocked message: Snowflake)
    func messageCell(_ cell: MessageCell, reply message: Snowflake)
}

extension MessageCellDelegate {
    func messageCell(_ cell: MessageCell, revealBlocked message: Snowflake) {}
}

/// Loads a remote image into an image view, ignoring stale completions.
final class RemoteImageView: UIImageView {
    private let loader: RasterMediaLoader
    private(set) var media: RasterMedia?
    private(set) var generation = 0
    private var source: URL?
    private var size = CGSize.zero
    private var kind: MediaKind = .image
    private var cancelLoad: (() -> Void)?
    private var requestedAnimation: Bool?
    private var failed = false
    private var retryAfter: TimeInterval = 0
    private var started: TimeInterval?
    private var lastFrame: UIImage?
    private var explicit: Bool?
    private let pauseBadge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    var onPlaybackChanged: (() -> Void)?
    var playbackEnabled = true { didSet { if !playbackEnabled { suspend() } } }
    var posterOnly = false
    var suppressed = false { didSet { if suppressed { suspend(); image = nil } } }
    var isPlaying: Bool { started != nil }
    var isAnimated: Bool { media?.isAnimated == true }
    var animationUnavailable: Bool { isAnimated && requestedAnimation == true && media?.frames.isEmpty == true }
    var canToggle: Bool { !posterOnly && isAnimated && (media?.frames.isEmpty == false || requestedAnimation == false) }

    init(frame: CGRect = .zero, loader: RasterMediaLoader = .shared) {
        self.loader = loader
        super.init(frame: frame)
        pauseBadge.tintColor = .white
        pauseBadge.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        pauseBadge.layer.cornerRadius = 4
        pauseBadge.isHidden = true
        addSubview(pauseBadge)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(12, bounds.width / 2)
        pauseBadge.frame = CGRect(x: bounds.width - side, y: bounds.height - side, width: side, height: side)
    }
    private func playbackChanged() {
        pauseBadge.isHidden = posterOnly || kind != .emoji || !isAnimated || animationUnavailable || isPlaying || suppressed
        onPlaybackChanged?()
    }

    func setImage(_ url: URL?, size: CGSize, kind: MediaKind = .image) {
        guard source != url || self.size != size || self.kind != kind else { return }
        suspend()
        source = url
        self.size = size
        self.kind = kind
        failed = false
        explicit = nil
        media = nil
        image = nil
        playbackChanged()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { MediaPlaybackScheduler.shared.remove(self); suspend() }
        else { MediaPlaybackScheduler.shared.add(self) }
    }
    override var isHidden: Bool { didSet { if isHidden { suspend() } } }

    func togglePlayback() {
        explicit = !isPlaying
        requestedAnimation = nil
        cancelLoad?(); cancelLoad = nil
        generation += 1
        started = nil
        playbackChanged()
    }

    func suspend() {
        cancelLoad?(); cancelLoad = nil
        generation += 1
        requestedAnimation = nil
        retryAfter = 0
        started = nil
        explicit = nil
        if let media {
            image = media.poster
            self.media = RasterMedia(poster: media.poster, frames: [], durations: [], byteCost: 0, isAnimated: media.isAnimated)
        }
        lastFrame = nil
        playbackChanged()
    }
}

extension RemoteImageView: MediaPlaybackParticipant {
    func mediaPolicyChanged() { suspend() }
    var playbackView: UIView { self }
    var usesVideoSlot: Bool { false }
    var playbackCost: Int {
        guard source != nil, !failed, !suppressed, !posterOnly, !animationUnavailable, playbackEnabled, MediaPlaybackPolicy.current.allows(kind, explicit: explicit),
              media?.isAnimated != false else { return 0 }
        return max(media?.byteCost ?? 0, RasterDecoder.decodedLimit)
    }
    func mediaTick(time: TimeInterval, visible: Bool, granted: Bool, policy: MediaPlaybackPolicy) {
        guard visible, playbackEnabled, !suppressed, let source else {
            if requestedAnimation != nil || started != nil { suspend() }
            return
        }
        guard !failed, time >= retryAfter else { return }
        let animate = !posterOnly && granted && policy.allows(kind, explicit: explicit)
        // Still assets don't need another request when autoplay changes.
        if requestedAnimation != animate && !(media?.isAnimated == false && requestedAnimation != nil) {
            cancelLoad?(); cancelLoad = nil
            generation += 1
            let current = generation
            requestedAnimation = animate
            started = nil
            if let media { image = media.poster }
            if !animate, let media {
                self.media = RasterMedia(poster: media.poster, frames: [], durations: [], byteCost: 0, isAnimated: media.isAnimated)
                playbackChanged()
                return
            }
            let pixel = max(1, min(1024, Int(max(size.width, size.height) * 3)))
            let key = RasterMediaLoader.Key(url: source, pixelSize: pixel, scale: 3, animate: animate)
            cancelLoad = loader.load(key) { [weak self] asset in
                guard let self, self.generation == current, !self.suppressed, self.playbackEnabled else { return }
                self.cancelLoad = nil
                self.failed = asset == nil
                self.media = asset
                self.image = asset?.poster
                self.playbackChanged()
            }
            if cancelLoad == nil {
                // Queue pressure is temporary. No subscription was installed;
                // retry at most four times per second while still visible.
                requestedAnimation = nil
                retryAfter = time + 0.25
            }
        }
        guard animate, let media, !media.frames.isEmpty else {
            if started != nil { started = nil; image = media?.poster; playbackChanged() }
            return
        }
        if started == nil { started = time; playbackChanged() }
        let frame = media.frame(at: time - (started ?? time))
        if frame !== lastFrame { image = frame; lastFrame = frame }
    }
}

final class MediaView: UIView {
    let imageView = RemoteImageView()
    private let play = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private let spoilerCover = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    private let spoilerLabel = UILabel()
    private let openButton = UIButton(type: .system)
    let video = InlineVideoPlayback()
    private var explicitVideo: Bool?
    private(set) var revealed = false
    var item: MediaItem?
    var onTap: ((MediaView) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        backgroundColor = Theme.elevated
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        layer.addSublayer(video.layer)
        video.onChange = { [weak self] in self?.updatePlaybackLabel() }
        imageView.onPlaybackChanged = { [weak self] in self?.updatePlaybackLabel() }
        play.tintColor = .white
        play.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        play.layer.shadowOpacity = 0.4
        play.layer.shadowRadius = 6
        addSubview(play)
        openButton.setImage(UIImage(systemName: "arrow.up.right.square.fill"), for: .normal)
        openButton.tintColor = .white
        openButton.accessibilityLabel = "Open media"
        openButton.addTarget(self, action: #selector(openMedia), for: .touchUpInside)
        addSubview(openButton)
        spoilerLabel.text = "SPOILER"
        spoilerLabel.font = Theme.font(13, .bold)
        spoilerLabel.textColor = .white
        spoilerLabel.textAlignment = .center
        spoilerCover.contentView.addSubview(spoilerLabel)
        addSubview(spoilerCover)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: MediaItem) {
        let changed = self.item != item
        if changed { video.reset(); explicitVideo = nil; revealed = !item.isSpoiler }
        self.item = item
        spoilerCover.isHidden = revealed
        imageView.suppressed = !revealed
        imageView.posterOnly = item.isVideo
        imageView.setImage(item.hasPoster ? item.url : nil, size: bounds.size)
        updatePlaybackLabel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.layer.frame = bounds
        CATransaction.commit()
        play.sizeToFit()
        play.center = CGPoint(x: bounds.midX, y: bounds.midY)
        spoilerCover.frame = bounds
        spoilerLabel.frame = spoilerCover.bounds
        openButton.frame = CGRect(x: max(0, bounds.width - 44), y: 0, width: 44, height: 44)
    }

    @objc private func tapped() {
        if !spoilerCover.isHidden {
            reveal()
            return
        }
        if item?.loopVideoURL != nil && !video.failed {
            explicitVideo = !video.hasWork
            if explicitVideo == false { video.stop() }
            updatePlaybackLabel()
        } else if imageView.canToggle {
            imageView.togglePlayback()
        } else { onTap?(self) }
    }

    func reveal() {
        revealed = true
        spoilerCover.isHidden = true
        imageView.suppressed = false
        updatePlaybackLabel()
    }
    func resetPlayback() {
        video.reset()
        item = nil
        revealed = false
        explicitVideo = nil
        imageView.setImage(nil, size: .zero)
    }
    @objc private func openMedia() { if revealed { onTap?(self) } }
    func togglePlayback() { tapped() }
    func togglePlaybackIfAnimated() {
        if revealed && (item?.loopVideoURL != nil || imageView.canToggle) { tapped() }
    }

    private func updatePlaybackLabel() {
        guard let item else { return }
        guard revealed else {
            accessibilityLabel = "Spoiler media"
            accessibilityHint = "Double-tap to reveal"
            accessibilityValue = nil
            openButton.isHidden = true
            play.isHidden = true
            accessibilityCustomActions = nil
            return
        }
        let animated = item.loopVideoURL != nil && !video.failed || imageView.isAnimated && !imageView.animationUnavailable
        let playing = item.loopVideoURL != nil ? video.isPlaying : imageView.isPlaying
        accessibilityLabel = item.alt ?? (animated ? "Animated image" : item.isVideo ? "Video" : "Image")
        accessibilityValue = animated ? (playing ? "Playing" : "Paused") : imageView.animationUnavailable || video.failed ? "Still preview" : nil
        accessibilityHint = animated ? "Double-tap to play or pause" : "Double-tap to open"
        play.image = UIImage(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
        play.isHidden = !animated && !item.isVideo
        openButton.isHidden = !animated
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Open media") { [weak self] _ in
            self?.openMedia(); return self != nil
        }]
    }
    override func accessibilityActivate() -> Bool { tapped(); return true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { MediaPlaybackScheduler.shared.remove(self); video.stop() }
        else { MediaPlaybackScheduler.shared.add(self) }
    }
    override var isHidden: Bool { didSet { if isHidden { video.stop(); imageView.suspend() } } }
}

extension MediaView: MediaPlaybackParticipant {
    func mediaPolicyChanged() { explicitVideo = nil; video.stop() }
    var playbackView: UIView { self }
    var usesVideoSlot: Bool { true }
    var playbackCost: Int {
        revealed && !video.failed && item?.loopVideoURL != nil && MediaPlaybackPolicy.current.allows(.image, explicit: explicitVideo) ? 1 : 0
    }
    func mediaTick(time: TimeInterval, visible: Bool, granted: Bool, policy: MediaPlaybackPolicy) {
        guard visible, revealed else { if video.hasWork { video.stop() }; explicitVideo = nil; return }
        guard granted, policy.allows(.image, explicit: explicitVideo), let url = item?.loopVideoURL else {
            if video.hasWork { video.stop() }; return
        }
        video.play(url)
    }
}

final class FileView: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "doc.fill"))
    private let name = UILabel()
    private let size = UILabel()
    private(set) var url: URL?
    private var file: FileItem?
    private(set) var revealed = false
    var onTap: ((URL) -> Void)?
    var onPresentationChanged: (() -> Void)?
    var actionTitle: String { url == nil ? "Reveal spoiler file" : "Open file \(file?.name ?? "")" }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.embedBackground
        layer.cornerRadius = 8
        layer.borderWidth = 1
        icon.tintColor = Theme.accent
        icon.contentMode = .scaleAspectFit
        name.font = Theme.font(15, .medium)
        name.textColor = Theme.link
        name.lineBreakMode = .byTruncatingMiddle
        size.font = Theme.small
        size.textColor = Theme.textMuted
        [icon, name, size].forEach(addSubview)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        registerForTraitChanges(UITraitCollection.colorTraits) { (self: Self, _) in self.applyLayerColors() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyLayerColors() {
        layer.borderColor = Theme.separator.resolvedColor(with: traitCollection).cgColor
    }

    func configure(_ file: FileItem) {
        if self.file != file { revealed = !file.isSpoiler }
        self.file = file
        updatePresentation()
    }

    func reset() {
        file = nil
        revealed = false
        url = nil
        name.text = nil
        size.text = nil
        accessibilityLabel = nil
        accessibilityHint = nil
    }

    func reveal() {
        guard file != nil else { return }
        revealed = true
        updatePresentation()
    }

    private func updatePresentation() {
        guard let file else { return }
        applyLayerColors()
        url = revealed ? file.url : nil
        name.text = revealed ? file.name : "Spoiler file"
        size.text = revealed ? ByteCountFormatter.string(fromByteCount: Int64(max(0, file.size)), countStyle: .file) : "Tap to reveal"
        accessibilityLabel = revealed ? "File \(file.name), \(size.text ?? "")" : "Spoiler file"
        accessibilityHint = revealed ? "Opens the file" : "Reveals the filename. Activate again to open."
        onPresentationChanged?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 12, y: (bounds.height - 30) / 2, width: 24, height: 30)
        name.frame = CGRect(x: 48, y: 9, width: bounds.width - 60, height: 20)
        size.frame = CGRect(x: 48, y: 29, width: bounds.width - 60, height: 18)
    }

    @objc private func tapped() { _ = activate() }
    private func activate() -> Bool {
        guard file != nil else { return false }
        if !revealed { reveal() }
        else if let url { onTap?(url) }
        return true
    }
    override func accessibilityActivate() -> Bool { activate() }
}

final class EmbedView: UIView {
    private let bar = UIView()
    let author = RichTextView()
    let title = RichTextView()
    let body = RichTextView()
    let footer = RichTextView()
    let image = MediaView()
    let thumbnail = RemoteImageView()
    private var fieldViews: [(RichTextView, RichTextView)] = []
    private let titleLink = UIControl()
    private var titleURL: URL?
    var onOpenURL: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        clipsToBounds = true
        bar.backgroundColor = Theme.quoteBar
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 6
        [bar, author, title, body, footer, image, thumbnail].forEach(addSubview)
        titleLink.addTarget(self, action: #selector(openTitle), for: .touchUpInside)
        addSubview(titleLink)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func openTitle() { if let titleURL { onOpenURL?(titleURL) } }
    func toggleAnimations() {
        for text in [author, title, body, footer] where !text.isHidden { text.toggleEmojiPlayback() }
        for pair in fieldViews where !pair.0.isHidden { pair.0.toggleEmojiPlayback(); pair.1.toggleEmojiPlayback() }
        if !image.isHidden { image.togglePlaybackIfAnimated() }
    }
    func revealSpoilers() {
        for text in [author, title, body, footer] where !text.isHidden { text.revealTextSpoilers() }
        for pair in fieldViews where !pair.0.isHidden { pair.0.revealTextSpoilers(); pair.1.revealTextSpoilers() }
        if !image.isHidden { image.reveal() }
    }

    func configure(_ embed: RenderedEmbed, layout: MessageLayout.EmbedLayout) {
        let origin = layout.frame.origin
        func local(_ rect: CGRect?) -> CGRect { rect.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) } ?? .zero }
        let mediaOnly = embed.author == nil && embed.title == nil && embed.body == nil && embed.fields.isEmpty && embed.footer == nil
        backgroundColor = mediaOnly ? .clear : Theme.embedBackground
        bar.isHidden = mediaOnly
        bar.backgroundColor = embed.color ?? Theme.quoteBar
        bar.frame = CGRect(x: 0, y: 0, width: 4, height: layout.frame.height)
        titleURL = embed.titleURL
        titleLink.isHidden = titleURL == nil
        titleLink.frame = local(layout.title)
        for (view, text, rect) in [(author, embed.author, layout.author), (title, embed.title, layout.title),
                                   (body, embed.body, layout.body), (footer, embed.footer, layout.footer)] {
            view.isHidden = text == nil
            view.frame = local(rect)
            view.setText(text)
        }
        while fieldViews.count < embed.fields.count {
            let pair = (RichTextView(), RichTextView())
            addSubview(pair.0); addSubview(pair.1)
            fieldViews.append(pair)
        }
        for (index, pair) in fieldViews.enumerated() {
            let visible = index < embed.fields.count && index < layout.fields.count
            pair.0.isHidden = !visible
            pair.1.isHidden = !visible
            guard visible else { continue }
            pair.0.frame = local(layout.fields[index].name)
            pair.1.frame = local(layout.fields[index].value)
            pair.0.setText(embed.fields[index].name)
            pair.1.setText(embed.fields[index].value)
            pair.0.onTap = { [weak self] tap in if case .link(let url) = tap { self?.onOpenURL?(url) } }
            pair.1.onTap = pair.0.onTap
        }
        if let item = embed.image, let rect = layout.image {
            image.isHidden = false
            image.frame = local(rect)
            image.configure(item)
        } else {
            image.isHidden = true
        }
        if let item = embed.thumbnail, let rect = layout.thumbnail {
            thumbnail.isHidden = false
            thumbnail.frame = local(rect)
            thumbnail.setImage(item.url, size: rect.size)
        } else {
            thumbnail.isHidden = true
        }
    }
}

final class ReactionPill: UIControl {
    private let emojiLabel = UILabel()
    private let emojiImage = RemoteImageView()
    private let countLabel = UILabel()
    var emoji: Emoji?
    /// Long press (or the VoiceOver action): who reacted.
    var onShowReactors: ((Emoji) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        emojiLabel.font = .systemFont(ofSize: 16)
        emojiLabel.textAlignment = .center
        emojiImage.contentMode = .scaleAspectFit
        countLabel.font = Theme.smallBold
        [emojiLabel, emojiImage, countLabel].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Touch and hold to see who reacted."
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.35
        addGestureRecognizer(press)
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Show Who Reacted") { [weak self] _ in
            guard let self, let emoji = self.emoji else { return false }
            self.onShowReactors?(emoji)
            return true
        }]
        registerForTraitChanges(UITraitCollection.colorTraits) { (self: Self, _) in self.applyLayerColors() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isMine = false
    func toggleAnimation() { if emojiImage.canToggle { emojiImage.togglePlayback() } }

    private func applyLayerColors() {
        layer.borderColor = (isMine ? Theme.reactionMineBorder : UIColor.clear).resolvedColor(with: traitCollection).cgColor
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let emoji else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onShowReactors?(emoji)
    }

    func configure(_ reaction: ReactionItem) {
        emoji = reaction.emoji
        backgroundColor = reaction.me ? Theme.reactionMine : Theme.reactionBackground
        isMine = reaction.me
        applyLayerColors()
        countLabel.textColor = reaction.me ? Theme.mentionText : Theme.textSecondary
        countLabel.text = reaction.countText
        if let url = reaction.emoji.url(size: 40) {
            emojiLabel.isHidden = true
            emojiImage.isHidden = false
            emojiImage.setImage(url, size: CGSize(width: 20, height: 20), kind: .emoji)
        } else {
            emojiImage.isHidden = true
            emojiLabel.isHidden = false
            emojiLabel.text = reaction.emoji.name
        }
        accessibilityLabel = "\(reaction.emoji.name ?? "emoji"), \(reaction.count)"
        accessibilityValue = reaction.me ? "You reacted" : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        emojiLabel.frame = CGRect(x: 8, y: (bounds.height - 20) / 2, width: 20, height: 20)
        emojiImage.frame = emojiLabel.frame
        countLabel.frame = CGRect(x: 34, y: 0, width: bounds.width - 40, height: bounds.height)
    }
}

/// The smiley-plus pill after a message's reactions: opens the emoji picker.
final class AddReactionPill: UIControl {
    private let face = UIImageView(image: UIImage(systemName: "face.smiling"))
    private let plus = UIImageView(image: UIImage(systemName: "plus.circle.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        backgroundColor = Theme.reactionBackground
        face.tintColor = Theme.textSecondary
        face.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        plus.tintColor = Theme.textSecondary
        plus.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        plus.backgroundColor = Theme.reactionBackground
        plus.layer.cornerRadius = 5
        plus.clipsToBounds = true
        [face, plus].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Add Reaction"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        face.sizeToFit()
        face.center = CGPoint(x: bounds.midX - 1, y: bounds.midY)
        plus.frame = CGRect(x: face.frame.maxX - 6, y: face.frame.minY - 2, width: 10, height: 10)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

/// A code block as a card: lines never wrap; the card scrolls sideways,
/// with a soft fade at the trailing edge while more code is off-screen.
final class CodeBlockView: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let label = UILabel()
    private let fade = CAGradientLayer()
    /// Shown while code runs past the edge: says "scroll sideways".
    private let more = UIImageView(image: UIImage(systemName: "chevron.right.2"))
    /// Opaque trailing gutter the cue sits on, so no code draws beneath it.
    private let gutter = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.codeBackground
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        clipsToBounds = true
        label.numberOfLines = 0
        label.lineBreakMode = .byClipping
        scroll.showsHorizontalScrollIndicator = true
        scroll.alwaysBounceHorizontal = false
        scroll.delegate = self
        scroll.addSubview(label)
        addSubview(scroll)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(fade)
        more.tintColor = Theme.textMuted
        more.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        more.isUserInteractionEnabled = false
        gutter.backgroundColor = Theme.codeBackground
        gutter.isUserInteractionEnabled = false
        addSubview(gutter)
        gutter.addSubview(more)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        registerForTraitChanges(UITraitCollection.colorTraits) { (self: Self, _) in self.applyLayerColors() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyLayerColors() {
        layer.borderColor = Theme.codeBorder.resolvedColor(with: traitCollection).cgColor
        let background = Theme.codeBackground.resolvedColor(with: traitCollection)
        fade.colors = [background.withAlphaComponent(0).cgColor, background.cgColor]
    }

    func configure(_ code: NSAttributedString, contentWidth: CGFloat) {
        label.attributedText = code
        accessibilityLabel = "Code: \(code.string)"
        let pad = MessageMetrics.codePadding
        scroll.frame = bounds
        label.frame = CGRect(x: pad, y: pad, width: max(contentWidth - pad * 2, bounds.width - pad * 2), height: bounds.height - pad * 2)
        scroll.contentSize = CGSize(width: max(bounds.width, contentWidth), height: bounds.height)
        scroll.contentOffset = .zero
        applyLayerColors()
        updateFade()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFade() }

    private func updateFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let overflow = scroll.contentSize.width - scroll.contentOffset.x - bounds.width
        let gutterWidth: CGFloat = 22
        gutter.frame = CGRect(x: bounds.width - gutterWidth, y: 0, width: gutterWidth, height: bounds.height)
        fade.frame = CGRect(x: bounds.width - gutterWidth - 16, y: 0, width: 16, height: bounds.height)
        fade.opacity = overflow > 1 ? 1 : 0
        more.sizeToFit()
        more.center = CGPoint(x: gutterWidth / 2, y: min(bounds.height / 2, 18))
        gutter.isHidden = overflow <= 1
        CATransaction.commit()
    }
}

final class MessageCell: UICollectionViewCell {
    weak var delegate: MessageCellDelegate?
    private(set) var messageID: Snowflake?
    private var authorID: Snowflake?
    private var replyID: Snowflake?

    private let blockedReveal = UIButton(type: .system)
    private var hidesBlocked = false
    private let highlight = UIView()
    private let highlightBar = UIView()
    private let avatar = RemoteImageView()
    private let systemIcon = UIImageView()
    private let nameLabel = UILabel()
    private let botBadge = UILabel()
    private let timeLabel = UILabel()
    private let replyCurve = CAShapeLayer()
    private let replyAvatar = RemoteImageView()
    private let replyLabel = UILabel()
    private let replyTap = UIView()
    private var textViews: [RichTextView] = []
    private var codeViews: [CodeBlockView] = []
    private var mediaViews: [MediaView] = []
    private var fileViews: [FileView] = []
    private var embedViews: [EmbedView] = []
    private var reactionViews: [ReactionPill] = []
    private let addReactionPill = AddReactionPill()
    private let statusLabel = UILabel()
    /// Over a failed send's status line: Retry or Delete.
    private let statusButton = UIButton(type: .system)
    /// Revealed at the trailing edge while the row is swiped to reply.
    private let replyArrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        replyArrow.tintColor = Theme.textSecondary
        replyArrow.contentMode = .center
        replyArrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        replyArrow.alpha = 0
        insertSubview(replyArrow, belowSubview: contentView)
        highlight.backgroundColor = Theme.mentionedRowBackground
        highlightBar.backgroundColor = Theme.mentionedRowBar
        highlight.addSubview(highlightBar)
        avatar.layer.cornerRadius = MessageMetrics.avatarSize / 2
        avatar.clipsToBounds = true
        avatar.backgroundColor = Theme.elevated
        avatar.isUserInteractionEnabled = true
        avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openAuthor)))
        systemIcon.tintColor = Theme.textMuted
        systemIcon.contentMode = .center
        systemIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        nameLabel.font = Theme.authorName
        nameLabel.isUserInteractionEnabled = true
        nameLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openAuthor)))
        botBadge.text = "APP"
        botBadge.font = Theme.font(10, .bold, style: .caption2)
        botBadge.textColor = .white
        botBadge.textAlignment = .center
        botBadge.backgroundColor = Theme.accent
        botBadge.layer.cornerRadius = 4
        botBadge.clipsToBounds = true
        timeLabel.font = Theme.timestamp
        timeLabel.textColor = Theme.textMuted
        replyCurve.fillColor = nil
        replyCurve.lineWidth = 2
        replyAvatar.layer.cornerRadius = 8
        replyAvatar.clipsToBounds = true
        replyLabel.font = Theme.small
        replyLabel.lineBreakMode = .byTruncatingTail
        replyTap.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openReply)))
        statusLabel.font = Theme.small
        contentView.layer.addSublayer(replyCurve)
        addReactionPill.addTarget(self, action: #selector(addReaction), for: .touchUpInside)
        [highlight, avatar, systemIcon, nameLabel, botBadge, timeLabel, replyAvatar, replyLabel, replyTap, statusLabel, statusButton, addReactionPill]
            .forEach(contentView.addSubview)
        blockedReveal.setTitle("Blocked message · Reveal", for: .normal)
        blockedReveal.backgroundColor = Theme.chatBackground
        blockedReveal.accessibilityLabel = "Reveal blocked message"
        blockedReveal.addAction(UIAction { [weak self] _ in self?.revealBlocked() }, for: .touchUpInside)
        contentView.addSubview(blockedReveal)
        statusButton.showsMenuAsPrimaryAction = true
        statusButton.accessibilityLabel = "Message options"
        isAccessibilityElement = true
        registerForTraitChanges(UITraitCollection.colorTraits) { (self: Self, _) in
            self.replyCurve.strokeColor = Theme.quoteBar.resolvedColor(with: self.traitCollection).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func textView(at index: Int) -> RichTextView {
        while textViews.count <= index {
            let view = RichTextView()
            view.onTap = { [weak self] tap in
                guard let self else { return }
                self.delegate?.messageCell(self, tap: tap)
            }
            contentView.addSubview(view)
            textViews.append(view)
        }
        return textViews[index]
    }

    private func codeView(at index: Int) -> CodeBlockView {
        while codeViews.count <= index {
            let view = CodeBlockView()
            contentView.addSubview(view)
            codeViews.append(view)
        }
        return codeViews[index]
    }

    @objc private func openAuthor() { if let authorID { delegate?.messageCell(self, openUser: authorID) } }
    @objc private func openReply() { if let replyID { delegate?.messageCell(self, jumpTo: replyID) } }
    @objc private func addReaction() { if let messageID { delegate?.messageCell(self, addReactionTo: messageID) } }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.bounds.origin.x = 0
        replyArrow.alpha = 0
        accessibilityCustomActions = nil
        fileActions = []
        func release(_ view: UIView) {
            if let file = view as? FileView { file.reset() }
            if let media = view as? MediaView { media.resetPlayback() }
            if let image = view as? RemoteImageView { image.setImage(nil, size: .zero) }
            if let text = view as? RichTextView { text.setText(nil) }
            for child in view.subviews { release(child) }
        }
        release(contentView)
    }

    /// Swipe-to-reply feedback: the row slides left by `offset`, revealing
    /// the reply arrow, which turns accent once releasing would reply.
    func setSwipe(offset: CGFloat, armed: Bool) {
        // Shifting the bounds (not a transform) survives the cell's layout
        // passes, which reset the content view's frame.
        contentView.bounds.origin.x = offset
        let size: CGFloat = 32
        replyArrow.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        replyArrow.center = CGPoint(x: bounds.width - min(offset, MessageListController.swipeThreshold) / 2 - 8,
                                    y: min(bounds.height, 56) / 2)
        replyArrow.alpha = min(1, offset / MessageListController.swipeThreshold)
        replyArrow.tintColor = armed ? Theme.accent : Theme.textSecondary
        replyArrow.transform = armed ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
    }

    func endSwipe() {
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            self.contentView.bounds.origin.x = 0
            self.replyArrow.alpha = 0
            self.replyArrow.transform = .identity
        }
    }

    func configure(_ message: RenderedMessage, layout: MessageLayout, width: CGFloat) {
        hidesBlocked = message.hidesBlocked
        blockedReveal.isHidden = !hidesBlocked
        // Reconfiguration releases old content loaders before installing a
        // privacy placeholder, including reused visible cells.
        if hidesBlocked { prepareForReuse() }
        messageID = message.id
        authorID = message.authorID
        replyID = message.reply?.messageID
        accessibilityLabel = message.accessibilityText
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        highlight.isHidden = !message.isMentioned
        highlight.frame = CGRect(x: 0, y: message.isContinuation ? 0 : MessageMetrics.groupTopPadding - 4, width: width,
                                 height: layout.height - (message.isContinuation ? 0 : MessageMetrics.groupTopPadding - 4))
        highlightBar.frame = CGRect(x: 0, y: 0, width: 2, height: highlight.bounds.height)

        if let frame = layout.avatar {
            if let icon = message.systemIcon {
                avatar.isHidden = true
                systemIcon.isHidden = false
                systemIcon.image = UIImage(systemName: icon)
                systemIcon.frame = frame
            } else {
                avatar.isHidden = false
                systemIcon.isHidden = true
                avatar.frame = frame
                avatar.setImage(message.avatarURL, size: frame.size, kind: .avatar)
            }
        } else {
            avatar.isHidden = true
            systemIcon.isHidden = true
        }

        if let header = layout.header, message.systemIcon == nil {
            nameLabel.isHidden = false
            timeLabel.isHidden = false
            nameLabel.text = message.authorName
            nameLabel.textColor = message.authorColor
            let nameWidth = min(ceil(nameLabel.sizeThatFits(CGSize(width: header.width, height: header.height)).width), header.width * 0.65)
            nameLabel.frame = CGRect(x: header.minX, y: header.minY, width: nameWidth, height: header.height)
            var x = nameLabel.frame.maxX + 6
            botBadge.isHidden = !message.isBot
            if message.isBot {
                let badge = botBadge.sizeThatFits(CGSize(width: 80, height: header.height))
                let badgeHeight = ceil(badge.height + 2)
                botBadge.frame = CGRect(x: x, y: header.midY - badgeHeight / 2, width: ceil(badge.width + 8), height: badgeHeight)
                x = botBadge.frame.maxX + 6
            }
            // Full stamp when it fits; otherwise just the time, never "10:…".
            let room = max(0, header.maxX - x)
            let full = (message.timestamp as NSString).size(withAttributes: [.font: Theme.timestamp]).width
            timeLabel.text = full <= room ? message.timestamp : message.shortTime
            timeLabel.frame = CGRect(x: x, y: header.minY + 1, width: room, height: header.height)
        } else {
            nameLabel.isHidden = true
            timeLabel.isHidden = true
            botBadge.isHidden = true
        }

        if let reply = message.reply, let frame = layout.reply {
            replyCurve.isHidden = false
            replyCurve.strokeColor = Theme.quoteBar.resolvedColor(with: traitCollection).cgColor
            replyAvatar.isHidden = reply.avatarURL == nil
            replyLabel.isHidden = false
            replyTap.isHidden = false
            let path = UIBezierPath()
            let startX = MessageMetrics.sideInset + MessageMetrics.avatarSize / 2
            path.move(to: CGPoint(x: startX, y: frame.maxY + 4))
            path.addLine(to: CGPoint(x: startX, y: frame.midY + 6))
            path.addQuadCurve(to: CGPoint(x: startX + 6, y: frame.midY), controlPoint: CGPoint(x: startX, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.minX + 20, y: frame.midY))
            replyCurve.path = path.cgPath
            replyAvatar.frame = CGRect(x: frame.minX + 24, y: frame.midY - 8, width: 16, height: 16)
            replyAvatar.setImage(reply.avatarURL, size: CGSize(width: 16, height: 16), kind: .avatar)
            let text = NSMutableAttributedString(string: reply.name.isEmpty ? "" : "@\(reply.name)  ",
                                                 attributes: [.font: Theme.smallBold, .foregroundColor: reply.nameColor])
            text.append(NSAttributedString(string: reply.snippet, attributes: [.font: Theme.small, .foregroundColor: Theme.textSecondary]))
            replyLabel.attributedText = text
            let labelX = reply.avatarURL == nil ? frame.minX + 24 : frame.minX + 46
            replyLabel.frame = CGRect(x: labelX, y: frame.minY, width: frame.maxX - labelX, height: frame.height)
            replyTap.frame = frame
        } else {
            replyCurve.isHidden = true
            replyAvatar.isHidden = true
            replyLabel.isHidden = true
            replyTap.isHidden = true
        }

        // Body segments: text runs and code cards, in order.
        var textIndex = 0, codeIndex = 0
        let segmentSource = message.systemIcon != nil ? (message.body.map { [MarkdownRenderer.Segment.text($0)] } ?? []) : message.segments
        let frames: [(frame: CGRect, contentWidth: CGFloat)] = message.systemIcon != nil ? (layout.body.map { [($0, $0.width)] } ?? []) : layout.segments
        for (segment, frame) in zip(segmentSource, frames) {
            switch segment {
            case .text(let text):
                let view = textView(at: textIndex)
                textIndex += 1
                view.isHidden = false
                view.frame = frame.frame
                view.setText(text)
            case .code(let code):
                let view = codeView(at: codeIndex)
                codeIndex += 1
                view.isHidden = false
                view.frame = frame.frame
                view.configure(code, contentWidth: frame.contentWidth)
            }
        }
        for view in textViews.dropFirst(textIndex) { view.isHidden = true; view.setText(nil) }
        for view in codeViews.dropFirst(codeIndex) { view.isHidden = true }

        while mediaViews.count < message.media.count {
            let view = MediaView()
            view.onTap = { [weak self] view in
                guard let self, let item = view.item else { return }
                self.delegate?.messageCell(self, open: item, from: view)
            }
            contentView.addSubview(view)
            mediaViews.append(view)
        }
        for (index, view) in mediaViews.enumerated() {
            let visible = index < message.media.count && index < layout.media.count
            view.isHidden = !visible
            if visible {
                view.frame = layout.media[index]
                view.layoutIfNeeded()
                view.configure(message.media[index])
            }
        }

        while fileViews.count < message.files.count {
            let view = FileView()
            view.onPresentationChanged = { [weak self] in self?.refreshFileActionNames() }
            view.onTap = { [weak self] url in
                guard let self else { return }
                self.delegate?.messageCell(self, tap: .link(url))
            }
            contentView.addSubview(view)
            fileViews.append(view)
        }
        for (index, view) in fileViews.enumerated() {
            let visible = index < message.files.count && index < layout.files.count
            view.isHidden = !visible
            if visible {
                view.frame = layout.files[index]
                view.configure(message.files[index])
            }
        }

        while embedViews.count < message.embeds.count {
            let view = EmbedView()
            view.onOpenURL = { [weak self] url in
                guard let self else { return }
                self.delegate?.messageCell(self, tap: .link(url))
            }
            view.image.onTap = { [weak self] media in
                guard let self, let item = media.item else { return }
                self.delegate?.messageCell(self, open: item, from: media)
            }
            for text in [view.body, view.title, view.author, view.footer] {
                text.onTap = { [weak self] tap in
                    guard let self else { return }
                    self.delegate?.messageCell(self, tap: tap)
                }
            }
            contentView.addSubview(view)
            embedViews.append(view)
        }
        for (index, view) in embedViews.enumerated() {
            let visible = index < message.embeds.count && index < layout.embeds.count
            view.isHidden = !visible
            if visible {
                view.frame = layout.embeds[index].frame
                view.configure(message.embeds[index], layout: layout.embeds[index])
            }
        }

        while reactionViews.count < message.reactions.count {
            let pill = ReactionPill()
            pill.addTarget(self, action: #selector(reactionTapped(_:)), for: .touchUpInside)
            pill.onShowReactors = { [weak self] emoji in
                guard let self, let id = self.messageID else { return }
                self.delegate?.messageCell(self, showReactions: emoji, on: id)
            }
            contentView.addSubview(pill)
            reactionViews.append(pill)
        }
        for (index, pill) in reactionViews.enumerated() {
            let visible = index < message.reactions.count && index < layout.reactions.count
            pill.isHidden = !visible
            if visible {
                pill.frame = layout.reactions[index]
                pill.configure(message.reactions[index])
            }
        }
        if message.showsAddReaction, let frame = layout.addReaction {
            addReactionPill.isHidden = false
            addReactionPill.frame = frame
        } else {
            addReactionPill.isHidden = true
        }

        statusButton.isHidden = true
        if let state = message.sendState, let frame = layout.status {
            statusLabel.isHidden = false
            statusLabel.frame = frame
            switch state {
            case .sending:
                statusLabel.text = "Sending…"
                statusLabel.textColor = Theme.textMuted
            case .failed(let error):
                statusLabel.text = "Couldn't send · Tap to retry or delete"
                statusLabel.textColor = Theme.unread
                // The whole line opens the choice; the menu's title says why it failed.
                statusButton.isHidden = false
                statusButton.frame = frame.insetBy(dx: 0, dy: min(0, (frame.height - 44) / 2))
                statusButton.accessibilityLabel = "Couldn't send: \(error). Retry or delete"
                let id = message.id
                statusButton.menu = UIMenu(title: error, children: [
                    UIAction(title: "Retry Send", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                        guard let self else { return }
                        self.delegate?.messageCell(self, retry: id)
                    },
                    UIAction(title: "Delete Message", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                        guard let self else { return }
                        self.delegate?.messageCell(self, discard: id)
                    },
                ])
            }
        } else {
            statusLabel.isHidden = true
        }

        // Reactions stay reachable with VoiceOver as actions on the message.
        var actions = message.reactions.map { reaction in
            UIAccessibilityCustomAction(name: "\(reaction.me ? "Remove" : "Add") reaction \(reaction.emoji.name ?? "")") { [weak self] _ in
                guard let self, let id = self.messageID else { return false }
                self.delegate?.messageCell(self, toggleReaction: reaction.emoji, on: id)
                return true
            }
        }
        actions.append(UIAccessibilityCustomAction(name: "Play or pause animations") { [weak self] _ in
            guard let self else { return false }
            for view in self.textViews where !view.isHidden { view.toggleEmojiPlayback() }
            for view in self.mediaViews where !view.isHidden && view.revealed { view.togglePlaybackIfAnimated() }
            for view in self.embedViews where !view.isHidden { view.toggleAnimations() }
            for pill in self.reactionViews where !pill.isHidden { pill.toggleAnimation() }
            return true
        })
        actions.append(UIAccessibilityCustomAction(name: "Reveal spoilers") { [weak self] _ in
            guard let self else { return false }
            for view in self.textViews where !view.isHidden { view.revealTextSpoilers() }
            for view in self.mediaViews where !view.isHidden { view.reveal() }
            for view in self.embedViews where !view.isHidden { view.revealSpoilers() }
            for view in self.fileViews where !view.isHidden { view.reveal() }
            self.refreshFileActionNames()
            return true
        })
        if let first = message.reactions.first {
            actions.append(UIAccessibilityCustomAction(name: "Show Who Reacted") { [weak self] _ in
                guard let self, let id = self.messageID else { return false }
                self.delegate?.messageCell(self, showReactions: first.emoji, on: id)
                return true
            })
        }
        if message.sendState == nil, message.systemIcon == nil {
            actions.insert(UIAccessibilityCustomAction(name: "Reply") { [weak self] _ in
                guard let self, let id = self.messageID else { return false }
                self.delegate?.messageCell(self, reply: id)
                return true
            }, at: 0)
        }
        if message.sendState == nil {
            actions.append(UIAccessibilityCustomAction(name: "Add Reaction") { [weak self] _ in
                guard let self, let id = self.messageID else { return false }
                self.delegate?.messageCell(self, addReactionTo: id)
                return true
            })
        }
        // The cell is the VoiceOver element. Expose card links/media as
        // local actions rather than trapping them inside that element.
        if let thread = message.thread {
            actions.append(UIAccessibilityCustomAction(name: "Open thread \(thread.name)") { [weak self] _ in
                guard let self else { return false }
                self.delegate?.messageCell(self, tap: .channel(thread.id))
                return true
            })
        }
        for embed in message.embeds {
            if let url = embed.titleURL {
                actions.append(UIAccessibilityCustomAction(name: embed.title?.string ?? "Open link") { [weak self] _ in
                    guard let self else { return false }
                    self.delegate?.messageCell(self, tap: .link(url))
                    return true
                })
            }
        }
        for (index, embed) in message.embeds.enumerated() {
            if let item = embed.image, !item.isSpoiler {
                actions.append(UIAccessibilityCustomAction(name: "Open " + (item.alt ?? "media")) { [weak self] _ in
                    guard let self, index < self.embedViews.count else { return false }
                    self.delegate?.messageCell(self, open: item, from: self.embedViews[index].image)
                    return true
                })
            }
        }
        if hidesBlocked {
            blockedReveal.frame = CGRect(x: MessageMetrics.contentLeft, y: 0, width: max(80, width - MessageMetrics.contentLeft), height: layout.height)
            // Text views are added lazily during configuration. Keep the
            // reveal action above the placeholder's text hit area.
            contentView.bringSubviewToFront(blockedReveal)
            actions = [UIAccessibilityCustomAction(name: "Reveal blocked message") { [weak self] _ in
                self?.revealBlocked(); return true
            }]
        }
        fileActions = fileViews.filter { !$0.isHidden }.map { view in
            UIAccessibilityCustomAction(name: view.actionTitle) { [weak view] action in
                guard let view else { return false }
                let activated = view.accessibilityActivate()
                action.name = view.actionTitle
                return activated
            }
        }
        accessibilityCustomActions = actions + fileActions
    }

    private var fileActions: [UIAccessibilityCustomAction] = []
    private func refreshFileActionNames() {
        for (view, action) in zip(fileViews.filter { !$0.isHidden }, fileActions) { action.name = view.actionTitle }
    }

    private func revealBlocked() {
        guard hidesBlocked, let id = messageID else { return }
        delegate?.messageCell(self, revealBlocked: id)
    }
    override func accessibilityActivate() -> Bool {
        if hidesBlocked { revealBlocked(); return true }
        return super.accessibilityActivate()
    }

    /// Whether `point` (in the cell) is on a reaction pill, where a long
    /// press means "who reacted" rather than the message menu.
    func isOnReaction(_ point: CGPoint) -> Bool {
        reactionViews.contains { !$0.isHidden && $0.frame.contains(point) } || (!addReactionPill.isHidden && addReactionPill.frame.contains(point))
    }

    @objc private func reactionTapped(_ pill: ReactionPill) {
        guard let emoji = pill.emoji, let messageID else { return }
        delegate?.messageCell(self, toggleReaction: emoji, on: messageID)
    }
}

/// Day separators, the unread divider and the channel's start banner.
final class MarkerCell: UICollectionViewCell {
    private let label = UILabel()
    private let leftLine = UIView()
    private let rightLine = UIView()
    private let pill = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let icon = UIImageView()

    enum Kind { case day(String), unread, start(title: String, subtitle: String, icon: String), loading }
    private var kind: Kind = .loading
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = Theme.font(12, .semibold, style: .caption1)
        label.textAlignment = .center
        pill.text = "NEW"
        pill.font = Theme.font(10, .bold, style: .caption2)
        pill.textColor = .white
        pill.backgroundColor = Theme.unread
        pill.textAlignment = .center
        pill.layer.cornerRadius = 4
        pill.clipsToBounds = true
        titleLabel.font = Theme.font(26, .bold, style: .title1)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.numberOfLines = 2
        subtitleLabel.font = Theme.font(15)
        subtitleLabel.textColor = Theme.textSecondary
        subtitleLabel.numberOfLines = 3
        icon.tintColor = Theme.textPrimary
        icon.backgroundColor = Theme.elevated
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        icon.layer.cornerRadius = 34
        icon.clipsToBounds = true
        spinner.color = Theme.textMuted
        [leftLine, rightLine, label, pill, titleLabel, subtitleLabel, icon, spinner].forEach(contentView.addSubview)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    static func height(_ kind: Kind, width: CGFloat) -> CGFloat {
        switch kind {
        case .day: return 40
        case .unread: return 24
        case .loading: return 52
        case .start(let title, let subtitle, _):
            let w = width - 32
            let t = TextMeasurer.size(NSAttributedString(string: title, attributes: [.font: Theme.font(26, .bold, style: .title1)]), width: w).height
            let s = TextMeasurer.size(NSAttributedString(string: subtitle, attributes: [.font: Theme.font(15)]), width: w).height
            return ceil(24 + 68 + 12 + min(t, 70) + 4 + min(s, 64) + 16)
        }
    }

    func configure(_ kind: Kind) {
        self.kind = kind
        [leftLine, rightLine, label, pill, titleLabel, subtitleLabel, icon].forEach { $0.isHidden = true }
        spinner.stopAnimating()
        switch kind {
        case .day(let text):
            label.isHidden = false; leftLine.isHidden = false; rightLine.isHidden = false
            label.text = text
            label.textColor = Theme.textMuted
            leftLine.backgroundColor = Theme.separator
            rightLine.backgroundColor = Theme.separator
            accessibilityLabel = text
        case .unread:
            leftLine.isHidden = false; pill.isHidden = false
            leftLine.backgroundColor = Theme.unread
            accessibilityLabel = "New messages"
        case .start(let title, let subtitle, let symbol):
            titleLabel.isHidden = false; subtitleLabel.isHidden = false; icon.isHidden = false
            titleLabel.text = title
            subtitleLabel.text = subtitle
            icon.image = UIImage(systemName: symbol)
            accessibilityLabel = "\(title). \(subtitle)"
        case .loading:
            spinner.startAnimating()
            accessibilityLabel = "Loading older messages"
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        switch kind {
        case .day:
            let size = label.sizeThatFits(b.size)
            label.frame = CGRect(x: (b.width - size.width) / 2 - 8, y: 0, width: size.width + 16, height: b.height)
            leftLine.frame = CGRect(x: 16, y: b.midY, width: label.frame.minX - 16, height: 1)
            rightLine.frame = CGRect(x: label.frame.maxX, y: b.midY, width: b.width - 16 - label.frame.maxX, height: 1)
        case .unread:
            pill.frame = CGRect(x: b.width - 16 - 36, y: b.midY - 8, width: 36, height: 16)
            leftLine.frame = CGRect(x: 16, y: b.midY, width: pill.frame.minX - 16, height: 1)
        case .start:
            icon.frame = CGRect(x: 16, y: 24, width: 68, height: 68)
            let w = b.width - 32
            let t = min(titleLabel.sizeThatFits(CGSize(width: w, height: 80)).height, 70)
            titleLabel.frame = CGRect(x: 16, y: icon.frame.maxY + 12, width: w, height: t)
            subtitleLabel.frame = CGRect(x: 16, y: titleLabel.frame.maxY + 4, width: w, height: min(subtitleLabel.sizeThatFits(CGSize(width: w, height: 80)).height, 64))
        case .loading:
            spinner.center = CGPoint(x: b.midX, y: b.midY)
        }
    }
}
