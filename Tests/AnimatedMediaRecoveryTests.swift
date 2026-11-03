import XCTest
@testable import DuocordNative

@MainActor
final class AnimatedMediaRecoveryTests: XCTestCase {
    private let policy = MediaPlaybackPolicy(autoplayGIFs: true, animateEmoji: true, reduceMotion: false)

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Media recovery did not complete")
    }

    nonisolated private final class HeldProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var active: [HeldProtocol] = []
        private static var stops = 0
        static var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
        static var activeCount: Int { lock.lock(); defer { lock.unlock() }; return active.count }
        static func complete(_ data: Data) {
            lock.lock(); let requests = active; active = []; lock.unlock()
            for request in requests {
                request.client?.urlProtocol(request, didLoad: data)
                request.client?.urlProtocolDidFinishLoading(request)
            }
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                                httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            Self.lock.lock(); Self.active.append(self); Self.lock.unlock()
        }
        override func stopLoading() {
            Self.lock.lock()
            Self.stops += 1
            Self.active.removeAll { $0 === self }
            Self.lock.unlock()
        }
    }

    private func heldLoader() -> RasterMediaLoader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldProtocol.self]
        return RasterMediaLoader(configuration: config)
    }

    func testSixFailedSourcesReleaseReservationsForValidAnimation() async throws {
        let views = (0..<6).map { index in
            let view = RemoteImageView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            view.setImage(URL(string: "unsupported://failed/\(index)")!, size: view.bounds.size)
            return view
        }
        let failures = expectation(description: "six terminal failures")
        failures.expectedFulfillmentCount = 6
        for view in views {
            view.onPlaybackChanged = { failures.fulfill(); view.onPlaybackChanged = nil }
            view.mediaTick(time: 0, visible: true, granted: true, policy: policy)
        }
        await fulfillment(of: [failures], timeout: 3)
        XCTAssertTrue(views.allSatisfy { $0.playbackCost == 0 }, "Failed images must release all six reservations")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        let scheduler = MediaPlaybackScheduler()
        for view in views { window.addSubview(view); scheduler.add(view) }
        let valid = RemoteImageView(frame: CGRect(x: 0, y: 30, width: 24, height: 24))
        valid.setImage(try XCTUnwrap(Bundle.main.url(forResource: "pulse", withExtension: "gif")), size: valid.bounds.size)
        window.addSubview(valid); scheduler.add(valid)
        try await eventually {
            scheduler.tick(active: true, policy: self.policy)
            return valid.isPlaying
        }
        XCTAssertTrue(valid.isPlaying)
        for view in views + [valid] { scheduler.remove(view); view.removeFromSuperview() }
    }

    func testSaturatedLoaderRetriesVisibleSurfaceAfterCapacityRecovers() async throws {
        let loader = heldLoader()
        var cancellations: [() -> Void] = []
        for index in 0..<48 {
            let cancel = loader.load(.init(url: URL(string: "https://recovery.invalid/hold/\(index)")!, pixelSize: 24, scale: 1, animate: false)) { _ in }
            if let cancel { cancellations.append(cancel) }
        }
        let view = RemoteImageView(frame: CGRect(x: 0, y: 0, width: 24, height: 24), loader: loader)
        view.setImage(try XCTUnwrap(Bundle.main.url(forResource: "pulse", withExtension: "gif")), size: view.bounds.size)
        view.mediaTick(time: CACurrentMediaTime(), visible: true, granted: true, policy: policy)
        // Let the rejected callback run before making room, matching the stuck view.
        try await Task.sleep(for: .milliseconds(30))
        for cancel in cancellations { cancel() }
        try await eventually {
            view.mediaTick(time: CACurrentMediaTime(), visible: true, granted: true, policy: self.policy)
            return view.media != nil
        }
        XCTAssertNotNil(view.image)
        XCTAssertEqual(view.media?.frames.count, 3)
        view.suspend()
    }

    func testCancelledEntryReplacementRetainsFinalConsumersCancellation() async throws {
        let loader = heldLoader()
        let key = RasterMediaLoader.Key(url: URL(string: "https://recovery.invalid/replacement")!, pixelSize: 24, scale: 1, animate: true)
        let unwanted = expectation(description: "cancelled consumers never receive pixels")
        unwanted.isInverted = true
        let first = loader.load(key) { _ in unwanted.fulfill() }
        try await eventually { HeldProtocol.activeCount > 0 }
        first?()
        let second = loader.load(key) { _ in unwanted.fulfill() }
        try await eventually { loader.requestCount == 2 && HeldProtocol.activeCount > 0 }
        let stops = HeldProtocol.stopCount
        second?()
        try await eventually { HeldProtocol.stopCount > stops }
        HeldProtocol.complete(Data())
        await fulfillment(of: [unwanted], timeout: 0.1)
    }

    private final class Probe: MediaPlaybackParticipant {
        let playbackView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let playbackCost = 0
        let usesVideoSlot = false
        var ticks = 0
        var granted = false
        func mediaTick(time: TimeInterval, visible: Bool, granted: Bool, policy: MediaPlaybackPolicy) {
            ticks += 1
            self.granted = granted
        }
    }

    func testSchedulerOverflowKeepsPosterTicksAndRecoversMembership() {
        let scheduler = MediaPlaybackScheduler()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.isHidden = false
        defer { window.isHidden = true }
        let probes = (0..<257).map { _ in Probe() }
        for probe in probes { window.addSubview(probe.playbackView); scheduler.add(probe) }
        scheduler.tick(active: true)
        XCTAssertGreaterThan(probes[256].ticks, 0, "Overflow still needs a poster path")
        XCTAssertFalse(probes[256].granted)
        scheduler.remove(probes[0])
        let before = probes[256].ticks
        scheduler.tick(active: true)
        XCTAssertGreaterThan(probes[256].ticks, before, "Membership must recover without a window transition")
        XCTAssertTrue(probes[256].granted)
        for probe in probes { scheduler.remove(probe) }
    }

    func testSixtyFiveStaticEmojiRemainVisibleWithoutMutatingCachedText() async throws {
        let attachment = EmojiAttachment(url: try XCTUnwrap(Bundle.main.url(forResource: "still", withExtension: "png")),
                                         name: "still", size: 20, font: Theme.body, animated: false)
        let text = NSMutableAttributedString()
        for _ in 0..<65 { text.append(NSAttributedString(attachment: attachment)) }
        let measured = TextMeasurer.size(text, width: 300)
        let rich = RichTextView(frame: CGRect(x: 0, y: 0, width: 300, height: measured.height))
        rich.setText(text)
        XCTAssertEqual(rich.emojiViews.count, 65)
        try await eventually {
            for emoji in rich.emojiViews {
                emoji.view.mediaTick(time: CACurrentMediaTime(), visible: true, granted: true, policy: self.policy)
            }
            return rich.emojiViews.allSatisfy { $0.view.image != nil }
        }
        XCTAssertNotNil(rich.emojiViews.last?.view.image)
        XCTAssertNil(attachment.image)
        XCTAssertEqual(TextMeasurer.size(text, width: 300), measured)
        rich.setText(nil)
    }

    func testDistinctEmojiOverflowKeepsPostersWithOnlySixtyFourAnimationCandidates() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "pulse", withExtension: "gif"))
        let text = NSMutableAttributedString()
        for index in 0..<65 {
            text.append(NSAttributedString(attachment: EmojiAttachment(url: url, name: "pulse\(index)", size: 20,
                                                                       font: Theme.body, animated: true)))
        }
        let rich = RichTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        rich.setText(text)
        XCTAssertEqual(rich.emojiViews.count, 65)
        XCTAssertEqual(rich.emojiViews.filter { !$0.view.posterOnly }.count, 64)
        let overflow = try XCTUnwrap(rich.emojiViews.last?.view)
        try await eventually {
            overflow.mediaTick(time: CACurrentMediaTime(), visible: true, granted: true, policy: self.policy)
            return overflow.media != nil
        }
        XCTAssertNotNil(overflow.image)
        XCTAssertTrue(overflow.media?.frames.isEmpty == true)
        XCTAssertFalse(overflow.isPlaying)
        XCTAssertFalse(overflow.canToggle, "Permanent posters must not offer an ineffective Play action")
        let badge = try XCTUnwrap(overflow.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertTrue(badge.isHidden, "Permanent posters must not display a Play badge")
        let eligible = try XCTUnwrap(rich.emojiViews.first?.view)
        let paused = MediaPlaybackPolicy(autoplayGIFs: false, animateEmoji: false, reduceMotion: false)
        try await eventually {
            eligible.mediaTick(time: CACurrentMediaTime(), visible: true, granted: true, policy: paused)
            return eligible.media != nil
        }
        XCTAssertTrue(eligible.canToggle, "An eligible paused animation still offers working playback")
        let eligibleBadge = try XCTUnwrap(eligible.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertFalse(eligibleBadge.isHidden)
        eligible.togglePlayback()
        try await eventually {
            eligible.mediaTick(time: CACurrentMediaTime(), visible: true, granted: true, policy: paused)
            return eligible.isPlaying
        }
        XCTAssertTrue(eligible.isPlaying)
        XCTAssertTrue(eligibleBadge.isHidden)
        rich.setText(nil)
    }
}
