import UIKit
import os

/// Where a channel was scrolled to: survives view rebuilds (fold, rotation,
/// size-class changes) and channel switches.
struct ScrollAnchor: Equatable {
    var itemID: String
    /// Item top minus the visible top, in points.
    var offset: CGFloat
    var pinnedToBottom: Bool
}

@MainActor
protocol MessageListHost: AnyObject {
    func list(openMedia item: MediaItem, from view: UIView)
    func list(openURL url: URL)
    func list(openUser user: Snowflake)
    func list(openChannel channel: Snowflake)
    func list(toggleReaction emoji: Emoji, on message: Snowflake)
    func list(showReactions emoji: Emoji, on message: Snowflake)
    func list(addReactionTo message: Snowflake)
    func list(reply message: Message)
    func list(retry message: Message)
    /// Drops a failed send.
    func list(discard message: Message)
    func list(edit message: Message)
    /// Deletes one of your messages (already confirmed by the reader).
    func list(delete message: Message)
    /// Pins or unpins a message (already confirmed by the reader).
    func list(setPinned pinned: Bool, message: Message)
    /// The quick reactions row: recently used first.
    func listQuickReactions() -> [String]
    func list(markUnread message: Message)
    func listReaderMoved()
    func list(firstVisible message: Snowflake?)
    func list(didReadUpTo message: Snowflake)
    func list(saveAnchor anchor: ScrollAnchor)
    func listNearBottomChanged(_ nearBottom: Bool)
}

/// The message list: a UICollectionView whose rows have exact precomputed
/// heights. Every change keeps the row the reader is looking at at the same
/// screen position, unless the reader is at the bottom, where it follows.
/// Rendered messages plus layouts for the last few widths (outer, inner,
/// book page), for one text size and theme. Shared by every list showing the channel
/// (two exist briefly while a fold swaps layouts), so layouts are always read
/// and written for an explicit width.
final class ListRenderCache {
    let category: UIContentSizeCategory
    /// Rendered text carries colours, so a theme change renders afresh.
    let theme: Int
    var rendered: [Snowflake: RenderedMessage] = [:]
    private var layouts: [CGFloat: [Snowflake: MessageLayout]] = [:]
    private var widthOrder: [CGFloat] = []

    init(category: UIContentSizeCategory, theme: Int = Theme.revision) {
        self.category = category
        self.theme = theme
    }

    func layout(_ id: Snowflake, width: CGFloat) -> MessageLayout? { layouts[width]?[id] }

    func setLayout(_ layout: MessageLayout, for id: Snowflake, width: CGFloat) {
        if layouts[width] == nil {
            widthOrder.append(width)
            // Keep the four most recent widths (outer, inner, book page, one
            // in transition); a list that misses its layout re-measures it.
            while widthOrder.count > 4 { layouts[widthOrder.removeFirst()] = nil }
        }
        layouts[width, default: [:]][id] = layout
    }

    /// A message's content changed: its layouts at every width are stale.
    func invalidate(_ id: Snowflake) {
        for key in layouts.keys { layouts[key]?[id] = nil }
    }

    func prune(keeping live: Set<Snowflake>) {
        rendered = rendered.filter { live.contains($0.key) }
        layouts = layouts.mapValues { $0.filter { live.contains($0.key) } }
    }
}

private final class ReaderCollectionView: UICollectionView {
    var readerScrollBegan: (() -> Bool)?
    var readerScrollEnded: ((Bool, Bool) -> Void)?

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let wasPinned = readerScrollBegan?() ?? false
        let handled = super.accessibilityScroll(direction)
        readerScrollEnded?(handled, wasPinned)
        return handled
    }
}

final class MessageListController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, MessageCellDelegate {
    enum Item: Hashable {
        case start
        case loading
        case day(Date)
        case unread
        case message(Snowflake)

        var key: String {
            switch self {
            case .start: "start"
            case .loading: "loading"
            case .day(let date): "day-\(Int(date.timeIntervalSince1970))"
            case .unread: "unread"
            case .message(let id): "m\(id)"
            }
        }
    }

    let timeline: MessageTimeline
    private let store: DiscordStore
    private let api: DiscordAPI
    private let guildID: Snowflake?
    private let channelTitle: String
    private let channelSubtitle: String
    private let channelIcon: String
    weak var host: MessageListHost?

    private let layout = MessageListLayout()
    private(set) var collectionView: UICollectionView!
    private var items: [Item] = []
    /// Lives on the timeline so a list recreated by a fold or size-class
    /// change reuses rendered messages and per-width layouts.
    private var cache: ListRenderCache {
        if let existing = timeline.renderCache as? ListRenderCache, existing.category == traitCollection.preferredContentSizeCategory,
           existing.theme == Theme.revision {
            return existing
        }
        let fresh = ListRenderCache(category: traitCollection.preferredContentSizeCategory)
        timeline.renderCache = fresh
        return fresh
    }

    private var layoutWidth: CGFloat = 0
    private var observation: UUID?
    private var unreadAfter: Snowflake?
    private var explicitUnreadTarget: Snowflake?
    private var pendingAnchor: ScrollAnchor?
    private var nearBottom = true
    private let jumpButton = UIButton(configuration: .filled())
    private let log = Logger(subsystem: "com.saphid.duocord.native", category: "list")
    private var contentSizeCategory: UIContentSizeCategory = .unspecified
    private var autoScroll: AutoScroller?

    init(timeline: MessageTimeline, store: DiscordStore, api: DiscordAPI, guildID: Snowflake?,
         title: String, subtitle: String, icon: String, anchor: ScrollAnchor?, unreadAfter: Snowflake?) {
        self.timeline = timeline
        self.store = store
        self.api = api
        self.guildID = guildID
        self.channelTitle = title
        self.channelSubtitle = subtitle
        self.channelIcon = icon
        self.pendingAnchor = anchor
        self.unreadAfter = unreadAfter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observation { MainActor.assumeIsolated { timeline.stopObserving(observation) } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The list is a child of the trailing conversation hosting controller.
        // Keep contextual presentations here instead of resolving to the split
        // view/window, which also contains the server and channel page.
        definesPresentationContext = true
        let reader = ReaderCollectionView(frame: view.bounds, collectionViewLayout: layout)
        reader.readerScrollBegan = { [weak self] in
            let previous = self?.pinned ?? false
            self?.pinned = false
            return previous
        }
        reader.readerScrollEnded = { [weak self] handled, previous in
            if !handled { self?.pinned = previous }
            else { self?.host?.listReaderMoved() }
            self?.updateNearBottom()
        }
        collectionView = reader
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = Theme.chatBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .always
        // The controls' fade reaches above them into the list; at the bottom
        // the newest message rests above it rather than under it.
        collectionView.contentInset.bottom = ChatControls.fadeHeight
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: "message")
        collectionView.register(MarkerCell.self, forCellWithReuseIdentifier: "marker")
        collectionView.accessibilityIdentifier = "messageList"
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidChange),
                                               name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        // Scrolling up to the top is how history loads; no tap-to-top jump.
        collectionView.scrollsToTop = false
        // Content fades softly under the title bar instead of a hard cut.
        collectionView.topEdgeEffect.style = .soft
        collectionView.addGestureRecognizer(replySwipe)
        view.addSubview(collectionView)

        var config = UIButton.Configuration.filled()
        config.title = "Latest"
        config.image = UIImage(systemName: "arrow.down")
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.accent
        config.baseForegroundColor = .white
        config.buttonSize = .medium
        jumpButton.configuration = config
        jumpButton.alpha = 0
        jumpButton.accessibilityIdentifier = "jumpToPresent"
        jumpButton.accessibilityLabel = "Jump to Present"
        jumpButton.addAction(UIAction { [weak self] _ in self?.jumpToPresent() }, for: .touchUpInside)
        jumpButton.layer.shadowOpacity = 0.25
        jumpButton.layer.shadowRadius = 8
        jumpButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        // The jump control lives in the SwiftUI strip above the composer
        // (outside the message viewport); this button stays hidden.
        jumpButton.isHidden = true

        observation = timeline.observe { [weak self] change in self?.apply(change) }
        contentSizeCategory = traitCollection.preferredContentSizeCategory
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.timeline.renderCache = nil
            self.rebuild(reason: "text size")
        }
        // Theme or light/dark change: cells re-render (layers hold resolved colours).
        registerForTraitChanges([ThemeRevisionTrait.self, UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.collectionView.backgroundColor = Theme.chatBackground
            self.rebuild(reason: "theme")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Parked just above the composer at the trailing edge, clear of text and the side bar.
        let size = jumpButton.sizeThatFits(view.bounds.size)
        jumpButton.frame = CGRect(x: view.bounds.width - view.safeAreaInsets.right - size.width - 12,
                                  y: view.bounds.height - view.safeAreaInsets.bottom - size.height - 8,
                                  width: size.width, height: size.height)
        if view.bounds.width > 0, view.bounds.width != layoutWidth {
            // The bounds have already changed, so use the anchor recorded at
            // the last scroll position rather than measuring now.
            let anchor = layoutWidth == 0 ? pendingAnchor : (pinned ? pinnedAnchor : (lastAnchor ?? captureAnchor()))
            if layoutWidth == 0, let pendingAnchor { pinned = pendingAnchor.pinnedToBottom }
            Perf.shared.record("widthChange", ["from": layoutWidth, "to": view.bounds.width, "pinned": anchor?.pinnedToBottom ?? false,
                                               "anchor": anchor?.itemID ?? "-", "hadLast": lastAnchor != nil])
            layoutWidth = view.bounds.width
            rebuild(reason: "width", anchor: anchor)
            pendingAnchor = nil
            // Posture changes animate and lay out in several passes; re-check
            // the pin after they settle.
            for delay in [0.15, 0.4, 0.9, 1.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.holdPin() }
            }
            #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self, let cv = self.collectionView else { return }
                Perf.shared.record("postWidth", ["pinned": self.pinned, "offset": Int(cv.contentOffset.y),
                                                 "bottom": Int(self.clampOffset(.greatestFiniteMagnitude)),
                                                 "tracking": cv.isTracking, "decel": cv.isDecelerating, "w": Int(self.layoutWidth),
                                                 "bounds": Int(cv.bounds.height), "content": Int(cv.contentSize.height)])
            }
            #endif
        } else if view.bounds.height != layoutHeight, layoutWidth > 0, pinned {
            // The keyboard or composer changed the height: keep following the newest message.
            collectionView.layoutIfNeeded()
            scrollToBottom(animated: false)
        }
        layoutHeight = view.bounds.height
        holdPin()
        clipAboveTitleBar()
    }

    /// The list runs under the title bar (for the soft edge) but never above
    /// it, where the status bar used to be.
    private func clipAboveTitleBar() {
        var bar: UINavigationBar? = navigationController?.navigationBar
        var parent = self.parent
        while bar == nil, let current = parent { bar = current.navigationController?.navigationBar; parent = current.parent }
        guard let bar, bar.window != nil else { view.layer.mask = nil; return }
        let top = max(0, bar.convert(bar.bounds, to: view).minY)
        guard top > 0 else { view.layer.mask = nil; return }
        let mask = (view.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.path = UIBezierPath(rect: CGRect(x: 0, y: top, width: view.bounds.width, height: max(0, view.bounds.height - top))).cgPath
        view.layer.mask = mask
    }

    private var layoutHeight: CGFloat = 0

    /// While following the newest message, every geometry change (fold
    /// animation, composer, keyboard, insets) keeps the list at the bottom.
    private func holdPin() {
        guard pinned, layoutWidth > 0, !timeline.hasMoreAfter, collectionView != nil,
              !collectionView.isTracking, !collectionView.isDecelerating else { return }
        let bottom = clampOffset(.greatestFiniteMagnitude)
        if abs(collectionView.contentOffset.y - bottom) > 0.5 {
            settingOffset = true
            collectionView.contentOffset.y = bottom
            settingOffset = false
        }
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) { holdPin() }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Keyboard or composer height changed: stay at the bottom if we were.
        guard layoutWidth > 0 else { return }
        if pinned {
            collectionView.layoutIfNeeded()
            scrollToBottom(animated: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Perf.shared.markOnce("firstChatAppear", extra: ["messages": timeline.messages.count])
        host?.listNearBottomChanged(nearBottom)
        #if DEBUG
        // `-DuocordPerfScroll YES`: run the scroll benchmark once history loads.
        if UserDefaults.standard.bool(forKey: "DuocordPerfScroll"), !Self.benchmarkStarted {
            Self.benchmarkStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.runScrollBenchmark(screens: UserDefaults.standard.integer(forKey: "DuocordPerfScreens").nonZero ?? 60) { result in
                    Perf.shared.record("scrollBenchmark", result)
                }
            }
        }
        #endif
    }

    private static var benchmarkStarted = false

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let anchor = captureAnchor() { host?.list(saveAnchor: anchor) }
    }

    // MARK: Building rows

    func setUnreadBoundary(_ boundary: Snowflake?, target: Snowflake?) {
        guard unreadAfter != boundary || explicitUnreadTarget != target else { return }
        unreadAfter = boundary
        explicitUnreadTarget = target
        if isViewLoaded { rebuild(reason: "read boundary") }
    }

    var unreadTarget: Snowflake? {
        if let explicitUnreadTarget { return explicitUnreadTarget }
        guard let unreadAfter,
              !timeline.hasMoreBefore || (timeline.messages.first?.id ?? Snowflake(UInt64.max)) <= unreadAfter else { return nil }
        return timeline.messages.first { $0.id > unreadAfter }?.id
    }

    private func buildItems() -> [Item] {
        var result: [Item] = []
        result.reserveCapacity(timeline.messages.count * 2 + 2)
        result.append(timeline.hasMoreBefore ? .loading : .start)
        var previousDay: Date?
        var placedUnread = false
        let unreadTarget = unreadTarget
        let calendar = Calendar.current
        for message in timeline.messages {
            let day = calendar.startOfDay(for: message.date)
            if day != previousDay {
                result.append(.day(day))
                previousDay = day
            }
            if !placedUnread, message.id == unreadTarget {
                result.append(.unread)
                placedUnread = true
            }
            result.append(.message(message.id))
        }
        if timeline.hasMoreAfter { result.append(.loading) }
        return result
    }

    private func height(for item: Item, width: CGFloat) -> CGFloat {
        switch item {
        case .start: MarkerCell.height(.start(title: channelTitle, subtitle: channelSubtitle, icon: channelIcon), width: width)
        case .loading: MarkerCell.height(.loading, width: width)
        case .day: MarkerCell.height(.day(""), width: width)
        case .unread: MarkerCell.height(.unread, width: width)
        case .message(let id): layoutFor(id, width: width)?.height ?? 44
        }
    }

    /// Renders messages whose content changed and lays out any without a
    /// layout at the current width (in parallel for big batches).
    /// A cached layout, or one measured now if it was evicted (never a blank row).
    private func layoutFor(_ id: Snowflake, width: CGFloat) -> MessageLayout? {
        if let cached = cache.layout(id, width: width) { return cached }
        guard let message = cache.rendered[id], width > 0 else { return nil }
        let layout = MessageLayoutEngine.layout(message, width: width)
        cache.setLayout(layout, for: id, width: width)
        return layout
    }

    private func prepare(invalidating changed: Set<Snowflake> = []) {
        let builder = MessageBuilder(store: store, guildID: guildID)
        let context = builder.context()
        let messages = timeline.messages
        var needsLayout: [Snowflake] = []
        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : nil
            let continuation = MessageBuilder.isContinuation(message, after: previous) && !builder.inputs(for: message).mentioned && !builder.inputs(for: message).hidesBlocked
            if let existing = cache.rendered[message.id], !changed.contains(message.id), existing.isContinuation == continuation,
               existing.source == MessageBuilder.sourceHash(message, inputs: builder.inputs(for: message)),
               (existing.sendState == nil) == (timeline.sendState(for: message) == nil) {
                if cache.layout(message.id, width: layoutWidth) == nil { needsLayout.append(message.id) }
                continue
            }
            cache.rendered[message.id] = builder.render(message, previous: previous, context: context, sendState: timeline.sendState(for: message))
            cache.invalidate(message.id)
            needsLayout.append(message.id)
        }
        // Forget rows that left the window.
        if cache.rendered.count > messages.count + 64 {
            cache.prune(keeping: Set(messages.map(\.id)))
        }
        guard !needsLayout.isEmpty, layoutWidth > 0 else { return }
        let width = layoutWidth
        let inputs = needsLayout.compactMap { cache.rendered[$0] }
        var outputs = [MessageLayout?](repeating: nil, count: inputs.count)
        let state = Perf.signposter.beginInterval("layout", "\(inputs.count) messages")
        if inputs.count > 24 {
            outputs.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
                    base[index] = MessageLayoutEngine.layout(inputs[index], width: width)
                }
            }
        } else {
            for (index, input) in inputs.enumerated() { outputs[index] = MessageLayoutEngine.layout(input, width: width) }
        }
        Perf.signposter.endInterval("layout", state)
        let cache = self.cache
        for (index, input) in inputs.enumerated() {
            if let layout = outputs[index] { cache.setLayout(layout, for: input.id, width: width) }
        }
    }

    func messageCell(_ cell: MessageCell, revealBlocked message: Snowflake) {
        store.revealBlockedMessage(message)
    }

    // MARK: Applying changes

    private func apply(_ change: TimelineChange) {
        guard isViewLoaded, layoutWidth > 0 else { return }
        switch change {
        case .appended(let count) where pinned && count <= 3 && !items.isEmpty:
            appendAnimated()
        case .updated(let ids):
            rebuild(reason: "update", changed: ids)
        case .prepended(let count):
            prepareOffMain(reason: "prepend \(count)")
        default:
            rebuild(reason: "\(change)")
        }
    }

    private var preparing = false
    private var rebuildAfterPrepare = false

    /// Renders and measures new messages on a background thread, then
    /// rebuilds on the main thread with everything already cached. The list
    /// keeps showing its current rows (its own `items`) meanwhile.
    private func prepareOffMain(reason: String) {
        guard !preparing else { rebuildAfterPrepare = true; return }
        let messages = timeline.messages
        let builder = MessageBuilder(store: store, guildID: guildID)
        let context = builder.context()
        var jobs: [(Message, Message?, MessageBuilder.Inputs, SendState?)] = []
        for (index, message) in messages.enumerated()
        where cache.rendered[message.id].map({ $0.source != MessageBuilder.sourceHash(message, inputs: builder.inputs(for: message)) }) ?? true {
            jobs.append((message, index > 0 ? messages[index - 1] : nil, builder.inputs(for: message), timeline.sendState(for: message)))
        }
        guard !jobs.isEmpty, layoutWidth > 0 else { rebuild(reason: reason); return }
        preparing = true
        let width = layoutWidth
        let targetCache = cache
        let privacyRevision = store.privacyRevision
        Task.detached(priority: .userInitiated) { [weak self] in
            var results = [(RenderedMessage, MessageLayout)?](repeating: nil, count: jobs.count)
            results.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                    let job = jobs[index]
                    let message = MessageBuilder.build(job.0, previous: job.1, inputs: job.2, context: context, sendState: job.3)
                    base[index] = (message, MessageLayoutEngine.layout(message, width: width))
                }
            }
            let finished = results.compactMap { $0 }
            await MainActor.run {
                guard let self else { return }
                self.preparing = false
                // Discard results if the width or text size changed meanwhile.
                if self.layoutWidth == width, self.cache === targetCache, self.store.privacyRevision == privacyRevision, self.view.window != nil {
                    let cache = targetCache
                    for (message, layout) in finished {
                        // A new render makes this message's layouts at other widths stale.
                        if cache.rendered[message.id]?.source != message.source { cache.invalidate(message.id) }
                        cache.rendered[message.id] = message
                        cache.setLayout(layout, for: message.id, width: width)
                    }
                }
                self.rebuildAfterPrepare = false
                // A list that left the screen (replaced during a fold) stays as it is.
                guard self.view.window != nil else { return }
                self.rebuild(reason: reason)
            }
        }
    }

    private func appendAnimated() {
        prepare()
        let newItems = buildItems()
        let oldKeys = Set(items.map(\.key))
        let inserted = newItems.enumerated().filter { !oldKeys.contains($0.element.key) }.map { IndexPath(item: $0.offset, section: 0) }
        // Only a pure tail append animates; anything else reloads in place.
        guard newItems.count == items.count + inserted.count, inserted.allSatisfy({ $0.item >= items.count }) else {
            rebuild(reason: "append")
            return
        }
        items = newItems
        layout.setHeights(items.map { height(for: $0, width: layoutWidth) })
        collectionView.performBatchUpdates {
            collectionView.insertItems(at: inserted)
        }
        scrollToBottom(animated: true)
    }

    func rebuild(reason: String, changed: Set<Snowflake> = [], anchor explicit: ScrollAnchor? = nil) {
        guard layoutWidth > 0 else { return }
        if preparing, changed.isEmpty, explicit == nil {
            rebuildAfterPrepare = true
            return
        }
        let anchor = explicit ?? captureAnchor()
        let state = Perf.signposter.beginInterval("rebuild", "\(reason)")
        let started = CACurrentMediaTime()
        defer { Perf.shared.record("rebuild", ["reason": reason, "ms": Int((CACurrentMediaTime() - started) * 1000), "rows": items.count]) }
        let before = anchor.flatMap { a in items.firstIndex { $0.key == a.itemID } }.map { layout.frame(at: $0).minY - collectionView.contentOffset.y }
        let t0 = CACurrentMediaTime()
        prepare(invalidating: changed)
        let t1 = CACurrentMediaTime()
        items = buildItems()
        layout.setHeights(items.map { height(for: $0, width: layoutWidth) })
        let t2 = CACurrentMediaTime()
        // Never animated, even when called from inside an animation (an alert
        // action runs during the alert's dismissal; inheriting it slid the
        // list off the newest message after a delete).
        UIView.performWithoutAnimation {
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            restore(anchor)
        }
        let t3 = CACurrentMediaTime()
        Perf.shared.record("rebuildParts", ["prepare": Int((t1 - t0) * 1000), "rows": Int((t2 - t1) * 1000), "reload": Int((t3 - t2) * 1000)])
        Perf.signposter.endInterval("rebuild", state)
        // Measured drift of the anchored row on screen: should be 0.
        if reason.hasPrefix("prepend"), let anchor, !anchor.pinnedToBottom,
           let index = items.firstIndex(where: { $0.key == anchor.itemID }), let before {
            let after = layout.frame(at: index).minY - collectionView.contentOffset.y
            Perf.shared.record("prependAnchor", ["drift": (after - before) * 10 / 10, "rows": items.count, "reason": reason])
        }
        updateNearBottom()
        lastAnchor = captureAnchor()
        // The rebuilt list is the new resting point for resize corrections.
        markResting()
        if let reveal = pendingReveal, items.contains(.message(reveal)) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingReveal == reveal else { return }
                self.reveal(reveal)
            }
        }
    }

    private var visibleTop: CGFloat { collectionView.contentOffset.y + collectionView.adjustedContentInset.top }

    private var pinnedAnchor: ScrollAnchor? {
        items.last.map { ScrollAnchor(itemID: $0.key, offset: 0, pinnedToBottom: true) }
    }

    func captureAnchor() -> ScrollAnchor? {
        guard collectionView != nil, !items.isEmpty else { return nil }
        if pinned && !timeline.hasMoreAfter { return pinnedAnchor }
        // Anchor to the first message row at least partly visible; marker
        // rows (loading, day) can come and go.
        var index = layout.index(at: visibleTop)
        for probe in index..<min(items.count, index + 4) {
            if case .message = items[probe] { index = probe; break }
        }
        let frame = layout.frame(at: index)
        return ScrollAnchor(itemID: items[index].key, offset: frame.minY - visibleTop, pinnedToBottom: false)
    }

    private func restore(_ anchor: ScrollAnchor?) {
        guard let anchor, !anchor.pinnedToBottom, let index = items.firstIndex(where: { $0.key == anchor.itemID }) else {
            if pinned || anchor?.pinnedToBottom == true || anchor == nil { scrollToBottom(animated: false) }
            return
        }
        pinned = false
        let target = layout.frame(at: index).minY - anchor.offset - collectionView.adjustedContentInset.top
        settingOffset = true
        collectionView.contentOffset.y = clampOffset(target)
        settingOffset = false
    }

    private func clampOffset(_ y: CGFloat) -> CGFloat {
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(minY, layout.collectionViewContentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        return min(max(y, minY), maxY)
    }

    func scrollToBottom(animated: Bool) {
        guard collectionView != nil else { return }
        if !timeline.hasMoreAfter { pinned = true }
        let y = clampOffset(.greatestFiniteMagnitude)
        if animated {
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        } else {
            settingOffset = true
            collectionView.contentOffset.y = y
            settingOffset = false
        }
    }

    private func isNearBottom() -> Bool {
        let bottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return bottom >= layout.collectionViewContentSize.height - 60 && !timeline.hasMoreAfter
    }

    private func updateNearBottom() {
        let first = collectionView.indexPathsForVisibleItems.sorted().compactMap { path -> Snowflake? in
            guard items.indices.contains(path.item), case .message(let id) = items[path.item] else { return nil }
            return id
        }.first
        host?.list(firstVisible: first)
        // Pinned counts as at the bottom: a geometry change mid-animation is
        // not the reader leaving the newest messages.
        let atBottom = isNearBottom()
        let near = atBottom || (pinned && !timeline.hasMoreAfter)
        if near != nearBottom {
            nearBottom = near
            host?.listNearBottomChanged(near)

        }
        if atBottom, let last = timeline.messages.last(where: { timeline.sendState(for: $0) == nil }) {
            host?.list(didReadUpTo: last.id)
        }
    }

    func jumpToPresent() {
        beginNavigation()
        host?.listReaderMoved()
        pinned = true
        if timeline.hasMoreAfter {
            navigationTask = Task { [timeline, api, store] in await timeline.loadLatestForJump(api: api, store: store) }
        } else {
            scrollToBottom(animated: true)
        }
    }

    /// Scrolls so `message` is centred and briefly highlighted.
    func reveal(_ message: Snowflake) {
        beginNavigation()
        guard let index = items.firstIndex(of: .message(message)) else {
            pendingReveal = message
            navigationTask = Task { [timeline, api, store] in await timeline.load(around: message, api: api, store: store) }
            return
        }
        pinned = false
        markResting() // the animated scroll below is the list's own move
        // Show the whole group (author line included), centred in the area
        // between the title bar and the composer.
        var start = index
        while start > 0, case .message(let id) = items[start], cache.rendered[id]?.isContinuation == true,
              case .message = items[start - 1] { start -= 1 }
        let inset = collectionView.adjustedContentInset
        let visible = collectionView.bounds.height - inset.top - inset.bottom
        let isNewest = !timeline.hasMoreAfter && !items[(index + 1)...].contains { if case .message = $0 { true } else { false } }
        let group = layout.frame(at: start).union(layout.frame(at: index))
        let frame = group.height <= visible - 24 ? group : layout.frame(at: index)
        if isNewest {
            // The newest message: follow the bottom as usual.
            scrollToBottom(animated: true)
        } else {
            let target = frame.midY - inset.top - visible / 2
            collectionView.setContentOffset(CGPoint(x: 0, y: clampOffset(target)), animated: true)
        }
        if let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) {
            flash(cell)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, let cell = self.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) else { return }
                self.flash(cell)
            }
        }
    }

    private var navigationTask: Task<Void, Never>?
    private var pendingReveal: Snowflake?

    private func beginNavigation() {
        navigationTask?.cancel()
        navigationTask = nil
        pendingReveal = nil
        timeline.retainCurrentWindowForNavigation()
    }
    private var lastAnchor: ScrollAnchor?
    /// Following the newest message. Only the reader's own scrolling (or a
    /// jump to an older message) clears it; geometry changes never do.
    private var pinned = true
    @objc private func keyboardDidChange() {
        holdPin()
        markResting()
        updateNearBottom()
    }

    private func flash(_ cell: UICollectionViewCell) {
        cell.contentView.backgroundColor = Theme.mentionBackground.withAlphaComponent(0.6)
        UIView.animate(withDuration: 1.2, delay: 0.4) { cell.contentView.backgroundColor = .clear }
    }

    // MARK: Scrolling and paging

    /// A programmatic reading move has the same intent as an accessibility
    /// scroll. Layout and keyboard offsets use their own correction paths.
    func scrollToHistoryOffset(_ offset: CGFloat) {
        pinned = false
        settingOffset = true
        collectionView.contentOffset.y = clampOffset(offset)
        settingOffset = false
        markResting()
        updateNearBottom()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if keepTopOnResize(scrollView) { return }
        if scrollView.isTracking || scrollView.isDecelerating {
            host?.listReaderMoved()
            pinned = isNearBottom()
        }
        updateNearBottom()
        if layoutWidth == scrollView.bounds.width { lastAnchor = captureAnchor() }
        let screens = (visibleTop) / max(1, scrollView.bounds.height)
        if screens < 1.5, timeline.hasMoreBefore, !timeline.loadingBefore {
            Task { [timeline, api, store] in await timeline.loadOlder(api: api, store: store) }
        }
        let remaining = (layout.collectionViewContentSize.height - scrollView.contentOffset.y - scrollView.bounds.height) / max(1, scrollView.bounds.height)
        if remaining < 1.5, timeline.hasMoreAfter, !timeline.loadingAfter {
            Task { [timeline, api, store] in await timeline.loadNewer(api: api, store: store) }
        }
    }

    /// Offset and height at the last scroll callback, to tell a resize from scrolling.
    /// Where the list last came to rest by the reader's scrolling or its own
    /// moves (rebuilds, anchors, reveals), and its height then.
    private var restingOffset: CGFloat = 0
    private var restingHeight: CGFloat = 0
    /// Set while the list moves itself (restoring an anchor, undoing a resize shift).
    private var settingOffset = false

    private func markResting() {
        restingOffset = collectionView.contentOffset.y
        restingHeight = collectionView.bounds.height
    }

    /// While reading history, the list getting shorter or taller without the
    /// reader scrolling (the history strip or typing line animating in, after
    /// returning from the sidebar) shifted rows by half the change. Keeps the
    /// top row where it was instead. True when it moved the list back.
    private func keepTopOnResize(_ scrollView: UIScrollView) -> Bool {
        if settingOffset || pinned || scrollView.isTracking || scrollView.isDecelerating || autoScroll != nil
            || layoutWidth != scrollView.bounds.width || restingHeight == 0 {
            markResting()
            return false
        }
        // Same height: the list moved for another reason (an animated reveal, clamping); follow it.
        guard scrollView.bounds.height != restingHeight else {
            restingOffset = scrollView.contentOffset.y
            return false
        }
        let keep = clampOffset(restingOffset)
        guard abs(scrollView.contentOffset.y - keep) > 0.5 else {
            // The resize didn't move the list: rest at the new height, so a
            // later scroll that isn't a touch (VoiceOver, a jump) isn't taken for one.
            markResting()
            return false
        }
        settingOffset = true
        scrollView.contentOffset.y = keep // re-enters scrollViewDidScroll, which does the usual work
        settingOffset = false
        markResting()
        return true
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { saveAnchor() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { saveAnchor() } }

    private func saveAnchor() { if let anchor = captureAnchor() { host?.list(saveAnchor: anchor) } }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = items[indexPath.item]
        switch item {
        case .message(let id):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "message", for: indexPath) as! MessageCell
            cell.delegate = self
            if let message = cache.rendered[id], let layout = layoutFor(id, width: layoutWidth) {
                cell.configure(message, layout: layout, width: layoutWidth)
            }
            return cell
        default:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "marker", for: indexPath) as! MarkerCell
            switch item {
            case .start: cell.configure(.start(title: channelTitle, subtitle: channelSubtitle, icon: channelIcon))
            case .loading: cell.configure(.loading)
            case .day(let date): cell.configure(.day(date.formatted(date: .long, time: .omitted)))
            case .unread: cell.configure(.unread)
            case .message: break
            }
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, case .message(let id) = items[indexPath.item],
              let message = timeline.messages.first(where: { $0.id == id }) else { return nil }
        if store.hidesBlockedMessage(message) {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [UIAction(title: "Reveal blocked message") { _ in self?.store.revealBlockedMessage(id) }])
            }
        }
        // A long press on a reaction shows who reacted instead.
        if let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
           cell.isOnReaction(collectionView.convert(point, to: cell)) { return nil }
        let mine = message.author.id == store.me?.id
        return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = []
            let sendState = self.timeline.sendState(for: message)
            if case .failed = sendState {
                // A send that didn't go: try again, or drop it (local only).
                actions.append(UIAction(title: "Retry Send", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.host?.list(retry: message)
                })
                actions.append(UIAction(title: "Delete Message", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.host?.list(discard: message)
                })
            }
            if sendState == nil {
                actions.append(UIAction(title: "Mark Unread", image: UIImage(systemName: "envelope.badge")) { [weak self] _ in
                    self?.host?.list(markUnread: message)
                })
                actions.append(UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
                    self?.host?.list(reply: message)
                })
                if mine, !message.isSystem {
                    actions.append(UIAction(title: "Edit Message", image: UIImage(systemName: "pencil")) { [weak self] _ in
                        self?.host?.list(edit: message)
                    })
                }
                let quick = (self.host?.listQuickReactions() ?? Self.defaultQuickReactions).map { emoji in
                    let action = UIAction(title: emoji, image: Self.emojiImage(emoji)) { [weak self] _ in
                        self?.host?.list(toggleReaction: Emoji(id: nil, name: emoji, animated: false), on: message.id)
                    }
                    if message.reactions.contains(where: { $0.me && $0.emoji.name == emoji && $0.emoji.id == nil }) { action.state = .on }
                    return action
                }
                actions.append(UIMenu(title: "Quick Reactions", options: [.displayInline, .displayAsPalette], children: quick))
                actions.append(UIAction(title: "Add Reaction", image: UIImage(systemName: "face.smiling")) { [weak self] _ in
                    self?.host?.list(addReactionTo: message.id)
                })
                if let title = self.pinMenuTitle(for: message) {
                    let pin = title == "Pin Message"
                    let action = UIAction(title: title, image: UIImage(systemName: pin ? "pin" : "pin.slash")) { [weak self] _ in
                        self?.confirmPin(message, pinned: pin)
                    }
                    // One change of a message's pin at a time.
                    if self.timeline.isChangingPin(message.id) { action.attributes = .disabled }
                    actions.append(action)
                }
            }
            if !message.content.isEmpty {
                actions.append(UIAction(title: "Copy Text", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = message.content
                })
            }
            let link = "https://discord.com/channels/\(message.guildID?.description ?? "@me")/\(message.channelID)/\(message.id)"
            actions.append(UIAction(title: "Copy Message Link", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.string = link
            })
            actions.append(UIAction(title: "Copy Message ID", image: UIImage(systemName: "number")) { _ in
                UIPasteboard.general.string = message.id.description
            })
            if sendState == nil, mine {
                // Destructive, last, and confirmed first.
                let delete = UIAction(title: "Delete Message", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDelete(message)
                }
                actions.append(UIMenu(options: .displayInline, children: [delete]))
            }
            return UIMenu(children: actions)
        }
    }

    static let defaultQuickReactions = ["👍", "❤️", "😂", "🎉", "👀"]

    /// Discord's confirmation before deleting your message.
    func confirmDelete(_ message: Message) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        present(deleteConfirmation(for: message), animated: true)
    }

    func deleteConfirmation(for message: Message) -> UIAlertController {
        let alert = UIAlertController(title: "Delete Message", message: "Are you sure you want to delete this message?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.host?.list(delete: message)
        })
        alert.view.accessibilityIdentifier = "confirmDelete"
        return alert
    }

    /// "Pin Message" or "Unpin Message" for the message as the window has it
    /// now; nil (no item) where it can't be pinned.
    func pinMenuTitle(for message: Message) -> String? {
        guard let current = timeline.messages.first(where: { $0.id == message.id }),
              timeline.canChangePin(current, store: store) else { return nil }
        return current.pinned ? "Unpin Message" : "Pin Message"
    }

    /// A pin posts a message everyone in the channel sees: confirm first.
    func confirmPin(_ message: Message, pinned: Bool) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        present(pinConfirmation(for: message, pinned: pinned), animated: true)
    }

    func pinConfirmation(for message: Message, pinned: Bool) -> UIAlertController {
        let alert = UIAlertController(title: pinned ? "Pin Message" : "Unpin Message",
                                      message: pinned ? "Pin this message to the channel? Everyone here will see that you pinned it."
                                                      : "Remove this message from the channel's pins?",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: pinned ? "Pin" : "Unpin", style: pinned ? .default : .destructive) { [weak self] _ in
            self?.host?.list(setPinned: pinned, message: message)
        })
        alert.view.accessibilityIdentifier = "confirmPin"
        return alert
    }

    // MARK: Cell delegate

    func messageCell(_ cell: MessageCell, open media: MediaItem, from view: UIView) { host?.list(openMedia: media, from: view) }

    func messageCell(_ cell: MessageCell, tap: RichTextView.Tap) {
        switch tap {
        case .link(let url): host?.list(openURL: url)
        case .user(let id): host?.list(openUser: id)
        case .channel(let id): host?.list(openChannel: id)
        }
    }

    func messageCell(_ cell: MessageCell, toggleReaction emoji: Emoji, on message: Snowflake) { host?.list(toggleReaction: emoji, on: message) }
    func messageCell(_ cell: MessageCell, showReactions emoji: Emoji, on message: Snowflake) { host?.list(showReactions: emoji, on: message) }
    func messageCell(_ cell: MessageCell, addReactionTo message: Snowflake) { host?.list(addReactionTo: message) }

    /// Emoji as menu images, so quick reactions show as a palette row.
    private static func emojiImage(_ emoji: String) -> UIImage {
        let size = CGSize(width: 30, height: 30)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let text = emoji as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 24)]
            let measured = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2), withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
    }
    func messageCell(_ cell: MessageCell, jumpTo message: Snowflake) { reveal(message) }
    func messageCell(_ cell: MessageCell, openUser user: Snowflake) { host?.list(openUser: user) }

    func messageCell(_ cell: MessageCell, retry message: Snowflake) {
        guard let original = timeline.messages.first(where: { $0.id == message }) else { return }
        host?.list(retry: original)
    }

    func messageCell(_ cell: MessageCell, discard message: Snowflake) {
        guard let original = timeline.messages.first(where: { $0.id == message }) else { return }
        host?.list(discard: original)
    }

    func messageCell(_ cell: MessageCell, reply message: Snowflake) {
        guard let original = timeline.messages.first(where: { $0.id == message }) else { return }
        host?.list(reply: original)
    }

    // MARK: Swipe to reply

    /// Discord iOS: drag a message leftwards to reply. Only a mostly
    /// horizontal, leftward drag starts it, so vertical scrolling and the
    /// rightward back / sidebar edge swipe are untouched.
    private lazy var replySwipe: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        pan.delegate = self
        return pan
    }()
    private weak var swipingCell: MessageCell?
    private var swipeArmed = false
    static let swipeThreshold: CGFloat = 64

    /// The message a swipe at `point` (collection view coordinates) would reply to.
    private func replyTarget(at point: CGPoint) -> (MessageCell, Message)? {
        guard let indexPath = collectionView.indexPathForItem(at: point), case .message(let id) = items[indexPath.item],
              let message = timeline.messages.first(where: { $0.id == id }), !message.isSystem,
              timeline.sendState(for: message) == nil,
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell else { return nil }
        return (cell, message)
    }

    @objc private func swiped(_ pan: UIPanGestureRecognizer) {
        let travel = max(0, -pan.translation(in: collectionView).x)
        switch pan.state {
        case .began:
            swipingCell = replyTarget(at: pan.location(in: collectionView))?.0
            swipeArmed = false
        case .changed:
            // Follows the finger up to the threshold, then resists.
            let threshold = Self.swipeThreshold
            let offset = travel <= threshold ? travel : threshold + (travel - threshold) * 0.25
            let armed = travel >= threshold
            if armed != swipeArmed {
                swipeArmed = armed
                if armed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            }
            swipingCell?.setSwipe(offset: offset, armed: armed)
        case .ended, .cancelled, .failed:
            if pan.state == .ended, swipeArmed, let cell = swipingCell, let id = cell.messageID,
               let message = timeline.messages.first(where: { $0.id == id }) {
                host?.list(reply: message)
            }
            swipingCell?.endSwipe()
            swipingCell = nil
            swipeArmed = false
        default:
            break
        }
    }

    // MARK: Perf harness

    /// Scrolls up through history at a steady speed while measuring frames,
    /// then back down: a repeatable scroll benchmark (debug launch argument).
    func runScrollBenchmark(screens: Int = 40, pointsPerSecond: CGFloat = 2400, completion: (([String: Any]) -> Void)? = nil) {
        pinned = false
        autoScroll = AutoScroller(list: self, distance: CGFloat(screens) * collectionView.bounds.height, speed: pointsPerSecond) { [weak self] result in
            self?.autoScroll = nil
            completion?(result)
        }
        autoScroll?.start()
    }
}

/// Drives contentOffset each frame for the scroll benchmark.
@MainActor
private final class AutoScroller {
    weak var list: MessageListController?
    let distance: CGFloat
    let speed: CGFloat
    let completion: ([String: Any]) -> Void
    private var link: CADisplayLink?
    private var travelled: CGFloat = 0
    private var last: CFTimeInterval = 0
    private var direction: CGFloat = -1

    init(list: MessageListController, distance: CGFloat, speed: CGFloat, completion: @escaping ([String: Any]) -> Void) {
        self.list = list
        self.distance = distance
        self.speed = speed
        self.completion = completion
    }

    func start() {
        Perf.shared.startFrames("scroll-up")
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let list, let collectionView = list.collectionView else { finish(); return }
        if last == 0 { last = link.timestamp; return }
        let dt = min(0.05, link.timestamp - last)
        last = link.timestamp
        let delta = speed * CGFloat(dt)
        travelled += delta
        let minY = -collectionView.adjustedContentInset.top
        var y = collectionView.contentOffset.y + direction * delta
        if direction < 0, (travelled >= distance || (y <= minY && !list.timeline.hasMoreBefore)) {
            let up = Perf.shared.stopFrames() ?? [:]
            Perf.shared.startFrames("scroll-down")
            direction = 1
            travelled = 0
            upResult = up
        } else if direction > 0, travelled >= distance || list.timeline.isAtLatest && collectionView.contentOffset.y >= collectionView.contentSize.height - collectionView.bounds.height {
            let down = Perf.shared.stopFrames() ?? [:]
            finish(down: down)
            return
        }
        y = max(minY, y)
        collectionView.contentOffset.y = y
        list.scrollViewDidScroll(collectionView)
    }

    private var upResult: [String: Any] = [:]

    private func finish(down: [String: Any] = [:]) {
        link?.invalidate()
        link = nil
        completion(["up": upResult, "down": down])
    }
}

extension MessageListController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === replySwipe, let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: collectionView)
        guard velocity.x < 0, abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
        return replyTarget(at: pan.location(in: collectionView)) != nil
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gesture === replySwipe else { return true }
        // Code cards scroll sideways themselves.
        var view = touch.view
        while let current = view, current !== collectionView {
            if current is UIScrollView { return false }
            view = current.superview
        }
        return true
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

extension MessageTimeline {
    /// Drops a jumped-to window and returns to the newest history.
    func loadLatestForJump(api: DiscordAPI, store: DiscordStore) async {
        guard !Task.isCancelled else { return }
        resetWindow()
        await loadLatest(api: api, store: store)
    }
}

extension ListCoordinator {
    func list(setPinned pinned: Bool, message: Message) { model?.setPinned(pinned, message: message) }
}
