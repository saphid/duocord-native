import XCTest
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
@testable import DuocordNative

@MainActor
final class AnimatedMediaTests: XCTestCase {
    private var context: RenderContext {
        RenderContext(userName: { _ in nil }, channelName: { _ in nil }, role: { _ in nil },
                      baseFont: Theme.body, textColor: Theme.textPrimary)
    }
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext))
    }
    private func decode(_ ext: String, animate: Bool = true, pixel: Int = 64) throws -> RasterMedia {
        try XCTUnwrap(RasterDecoder.decode(Data(contentsOf: fixture("pulse", ext)), pixelSize: pixel, scale: 1, animate: animate))
    }
    private func load(_ loader: RasterMediaLoader, _ key: RasterMediaLoader.Key) async -> RasterMedia? {
        await withCheckedContinuation { continuation in
            loader.load(key) { continuation.resume(returning: $0) }
        }
    }
    private func waitForLoad(_ view: RemoteImageView, animate: Bool = true) async throws {
        let ready = expectation(description: "view decoded")
        view.onPlaybackChanged = { [weak view] in if view?.media != nil { ready.fulfill(); view?.onPlaybackChanged = nil } }
        view.mediaTick(time: 0, visible: true, granted: true,
                       policy: MediaPlaybackPolicy(autoplayGIFs: animate, animateEmoji: animate, reduceMotion: false))
        await fulfillment(of: [ready], timeout: 5)
    }

    func testGIFAndAPNGDecodeRealFramesAndTiming() throws {
        for ext in ["gif", "png", "webp"] {
            let asset = try decode(ext)
            XCTAssertEqual(asset.frames.count, 3, ext)
            XCTAssertTrue(asset.isAnimated)
            XCTAssertEqual(asset.duration, 0.6, accuracy: 0.03, ext)
            XCTAssertEqual(asset.durations[0], 0.2, accuracy: 0.02, ext)
            XCTAssertTrue(asset.frame(at: 0.01) === asset.frames[0])
            XCTAssertTrue(asset.frame(at: 0.21) === asset.frames[1])
            XCTAssertTrue(asset.frame(at: 0.61) === asset.frames[0])
            XCTAssertNotEqual(asset.frames[0].pngData(), asset.frames[1].pngData())
        }
    }

    func testPosterDecodeAndStillAssetsStayStill() throws {
        let poster = try decode("gif", animate: false)
        XCTAssertTrue(poster.isAnimated)
        XCTAssertTrue(poster.frames.isEmpty)
        let still = try XCTUnwrap(RasterDecoder.decode(Data(contentsOf: fixture("still", "png")), pixelSize: 16, scale: 1, animate: true))
        XCTAssertFalse(still.isAnimated)
        XCTAssertTrue(still.frames.isEmpty)
        XCTAssertLessThanOrEqual(max(still.poster.size.width, still.poster.size.height), 16)
    }

    private func generatedGIF(frames: Int, side: Int) throws -> Data {
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, frames, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                             bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for index in 0..<frames {
            context.setFillColor((index.isMultiple(of: 2) ? UIColor.red : UIColor.blue).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    func testFrameAndDecodedBudgetsKeepPosterWithoutPartialPlayback() throws {
        let tooMany = try generatedGIF(frames: 121, side: 2)
        let result = try XCTUnwrap(RasterDecoder.decode(tooMany, pixelSize: 2, scale: 1, animate: true))
        XCTAssertTrue(result.isAnimated)
        XCTAssertTrue(result.frames.isEmpty)
        let tooLarge = try generatedGIF(frames: 10, side: 512)
        let fallback = try XCTUnwrap(RasterDecoder.decode(tooLarge, pixelSize: 512, scale: 1, animate: true))
        XCTAssertTrue(fallback.frames.isEmpty)
        XCTAssertNotNil(fallback.poster.cgImage)
        let small = try XCTUnwrap(RasterDecoder.decode(tooLarge, pixelSize: 64, scale: 1, animate: true))
        XCTAssertEqual(small.frames.count, 10)
        XCTAssertLessThan(small.byteCost, 1_000_000)
    }

    func testMalformedEncodedAndDimensionLimitsAndCancellation() throws {
        XCTAssertNil(RasterDecoder.decode(Data("not an image".utf8), pixelSize: 32, scale: 1, animate: true))
        XCTAssertNil(RasterDecoder.decode(Data(repeating: 0, count: 16 * 1024 * 1024 + 1), pixelSize: 32, scale: 1, animate: true))
        var gif = try Data(contentsOf: fixture("pulse", "gif"))
        // GIF logical-screen width: ImageIO can inspect it without decoding it.
        gif[6] = 255; gif[7] = 255
        XCTAssertNil(RasterDecoder.decode(gif, pixelSize: 32, scale: 1, animate: true))
        var checks = 0
        let cancelled = RasterDecoder.decode(try Data(contentsOf: fixture("pulse", "gif")), pixelSize: 32, scale: 1, animate: true) {
            checks += 1
            return checks > 3
        }
        XCTAssertNil(cancelled)
    }

    func testLoaderCacheSeparatesPosterAnimationScaleAndSize() async throws {
        let loader = RasterMediaLoader()
        let url = try fixture("pulse", "gif")
        let key = RasterMediaLoader.Key(url: url, pixelSize: 32, scale: 1, animate: true)
        let firstLoaded = await load(loader, key)
        let secondLoaded = await load(loader, key)
        let first = try XCTUnwrap(firstLoaded)
        let second = try XCTUnwrap(secondLoaded)
        XCTAssertTrue(first.poster === second.poster)
        let loadedPoster = await load(loader, .init(url: url, pixelSize: 32, scale: 1, animate: false))
        let poster = try XCTUnwrap(loadedPoster)
        XCTAssertTrue(poster.frames.isEmpty)
        XCTAssertFalse(first.poster === poster.poster)
        let loadedSmaller = await load(loader, .init(url: url, pixelSize: 12, scale: 2, animate: true))
        let smaller = try XCTUnwrap(loadedSmaller)
        XCTAssertLessThan(smaller.poster.size.width, first.poster.size.width)
        XCTAssertEqual(smaller.poster.scale, 2)
        XCTAssertEqual(loader.requestCount, 3)
    }

    func testCoalescedConsumerCancellationDoesNotCancelOtherView() async throws {
        let loader = RasterMediaLoader()
        let key = RasterMediaLoader.Key(url: try fixture("pulse", "gif"), pixelSize: 32, scale: 1, animate: true)
        let unwanted = expectation(description: "cancelled callback")
        unwanted.isInverted = true
        let wanted = expectation(description: "remaining consumer")
        let cancel = loader.load(key) { _ in unwanted.fulfill() }
        loader.load(key) { asset in XCTAssertEqual(asset?.frames.count, 3); wanted.fulfill() }
        cancel?()
        await fulfillment(of: [wanted, unwanted], timeout: 0.5)
        XCTAssertEqual(loader.requestCount, 1)
    }

    nonisolated private final class OfflineProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let route = request.url!.path
            let response = HTTPURLResponse(url: request.url!, statusCode: route == "/status" ? 404 : 200,
                                           httpVersion: "HTTP/1.1", headerFields: route == "/header" ? ["Content-Length": "20000000"] : [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if route == "/chunks" {
                let chunk = Data(repeating: 0, count: 1024 * 1024)
                for _ in 0..<17 { client?.urlProtocol(self, didLoad: chunk) }
            } else if route == "/valid", let url = Bundle.main.url(forResource: "pulse", withExtension: "gif"),
                      let data = try? Data(contentsOf: url) {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testOfflineStreamingTransportEnforcesHeaderChunkAndStatusLimits() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineProtocol.self]
        let loader = RasterMediaLoader(configuration: config)
        for path in ["header", "chunks", "status"] {
            let value = await load(loader, .init(url: URL(string: "https://offline.invalid/\(path)")!, pixelSize: 32, scale: 1, animate: true))
            XCTAssertNil(value, path)
        }
        let value = await load(loader, .init(url: URL(string: "https://offline.invalid/valid")!, pixelSize: 32, scale: 1, animate: true))
        XCTAssertEqual(value?.frames.count, 3)
    }

    func testReuseCancelsLateDecodeAndNilClearsOldPixels() async throws {
        let view = RemoteImageView(frame: CGRect(x: 0, y: 0, width: 32, height: 24))
        view.setImage(try fixture("pulse", "gif"), size: view.bounds.size)
        view.mediaTick(time: 0, visible: true, granted: true, policy: .init(autoplayGIFs: true, animateEmoji: true, reduceMotion: false))
        let generation = view.generation
        view.setImage(try fixture("still", "png"), size: view.bounds.size)
        try await waitForLoad(view)
        XCTAssertGreaterThan(view.generation, generation)
        XCTAssertFalse(try XCTUnwrap(view.media).isAnimated)
        view.setImage(nil, size: .zero)
        XCTAssertNil(view.image)
        XCTAssertNil(view.media)
    }

    func testViewPolicyPauseResumeHiddenBackgroundAndDeniedBudget() async throws {
        let view = RemoteImageView(frame: CGRect(x: 0, y: 0, width: 32, height: 24))
        view.setImage(try fixture("pulse", "gif"), size: view.bounds.size)
        try await waitForLoad(view)
        let normal = MediaPlaybackPolicy(autoplayGIFs: true, animateEmoji: true, reduceMotion: false)
        view.mediaTick(time: 1, visible: true, granted: true, policy: normal)
        XCTAssertTrue(view.isPlaying)
        view.mediaTick(time: 2, visible: true, granted: false, policy: normal)
        XCTAssertFalse(view.isPlaying)
        XCTAssertTrue(try XCTUnwrap(view.media).frames.isEmpty)
        view.mediaTick(time: 3, visible: false, granted: false, policy: normal)
        XCTAssertFalse(view.isPlaying)
        XCTAssertNotNil(view.image)
        try await waitForLoad(view, animate: false)
        view.mediaTick(time: 4, visible: true, granted: true, policy: .init(autoplayGIFs: true, animateEmoji: true, reduceMotion: true))
        XCTAssertFalse(view.isPlaying)
        view.togglePlayback()
        try await waitForLoad(view)
        view.mediaTick(time: 5, visible: true, granted: true, policy: .init(autoplayGIFs: false, animateEmoji: false, reduceMotion: true))
        XCTAssertTrue(view.isPlaying, "Explicit play can override reduced autoplay")
        view.mediaPolicyChanged()
        view.mediaTick(time: 6, visible: true, granted: true, policy: .init(autoplayGIFs: false, animateEmoji: false, reduceMotion: true))
        XCTAssertFalse(view.isPlaying, "A fresh system/preference change resets the earlier explicit play choice")
        view.isHidden = true
        XCTAssertFalse(view.isPlaying)
        XCTAssertTrue(try XCTUnwrap(view.media).frames.isEmpty)
    }

    func testVisibilityUsesViewportAndHiddenAncestors() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let clip = UIView(frame: CGRect(x: 10, y: 10, width: 80, height: 80))
        clip.clipsToBounds = true
        window.addSubview(clip)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        clip.addSubview(view)
        XCTAssertTrue(MediaVisibility.isVisible(view))
        view.frame.origin.y = 100
        XCTAssertFalse(MediaVisibility.isVisible(view), "Attached to a window but outside scroll viewport")
        view.frame.origin.y = 0
        clip.isHidden = true
        XCTAssertFalse(MediaVisibility.isVisible(view))
        clip.isHidden = false
        clip.alpha = 0
        XCTAssertFalse(MediaVisibility.isVisible(view))
        window.isHidden = true
    }

    func testInlineEmojiViewsOwnPlaybackWithoutMutatingSharedAttachmentOrGeometry() async throws {
        let attachment = EmojiAttachment(url: try fixture("pulse", "gif"), name: "pulse", size: 20, font: Theme.body, animated: true)
        let text = NSMutableAttributedString(string: "before ", attributes: [.font: Theme.body])
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " after", attributes: [.font: Theme.body]))
        let before = TextMeasurer.size(text, width: 240)
        let first = RichTextView(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        let second = RichTextView(frame: first.frame)
        first.setText(text); second.setText(text)
        first.layoutIfNeeded(); second.layoutIfNeeded()
        let one = try XCTUnwrap(first.emojiViews.first?.view)
        let two = try XCTUnwrap(second.emojiViews.first?.view)
        XCTAssertFalse(one === two)
        try await waitForLoad(one)
        one.mediaTick(time: 1, visible: true, granted: true, policy: .init(autoplayGIFs: true, animateEmoji: true, reduceMotion: false))
        XCTAssertTrue(one.isPlaying)
        XCTAssertFalse(two.isPlaying)
        XCTAssertNil(attachment.image, "Render/cache attachment must remain immutable")
        XCTAssertEqual(one.frame.size, CGSize(width: 20, height: 20))
        XCTAssertEqual(TextMeasurer.size(text, width: 240), before)
        first.setText(nil)
        XCTAssertNil(one.image)
        XCTAssertTrue(first.emojiViews.isEmpty)
    }

    func testSpoilerEmojiNeverLoadsOrExposesHiddenMediaBeforeReveal() throws {
        let attachment = EmojiAttachment(url: try fixture("pulse", "gif"), name: "secret", size: 20, font: Theme.body, animated: true)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttribute(.dcSpoiler, value: 7, range: NSRange(location: 0, length: text.length))
        let rich = RichTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        rich.setText(text)
        let emoji = try XCTUnwrap(rich.emojiViews.first?.view)
        emoji.mediaTick(time: 0, visible: true, granted: true, policy: .init(autoplayGIFs: true, animateEmoji: true, reduceMotion: false))
        XCTAssertTrue(emoji.suppressed)
        XCTAssertNil(emoji.image)
        XCTAssertNil(emoji.media)
        rich.revealSpoiler(7)
        XCTAssertFalse(emoji.suppressed)
        let media = MediaView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        media.configure(.init(url: attachment.url, openURL: URL(string: "https://example.com/secret")!, width: 32, height: 24,
                              isVideo: false, isSpoiler: true, alt: "secret filename"))
        XCTAssertEqual(media.accessibilityLabel, "Spoiler media")
        XCTAssertNil(media.accessibilityCustomActions)
        XCTAssertTrue(media.imageView.suppressed)
        media.reveal()
        XCTAssertEqual(media.accessibilityLabel, "secret filename")
        XCTAssertFalse(media.imageView.suppressed)
    }

    func testPreferencesPersistAndReduceMotionKeepsIndependentAutoplayControls() {
        let name = "duocord-animated-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.autoplayGIFs)
        XCTAssertTrue(settings.animateEmoji)
        settings.autoplayGIFs = false
        settings.animateEmoji = true
        let restored = AppSettings(defaults: defaults)
        XCTAssertFalse(restored.autoplayGIFs)
        XCTAssertTrue(restored.animateEmoji)
        var policy = MediaPlaybackPolicy(autoplayGIFs: restored.autoplayGIFs, animateEmoji: restored.animateEmoji, reduceMotion: false)
        XCTAssertFalse(policy.allows(.image, explicit: nil))
        XCTAssertTrue(policy.allows(.emoji, explicit: nil))
        policy.reduceMotion = true
        XCTAssertFalse(policy.allows(.emoji, explicit: nil))
        XCTAssertTrue(policy.allows(.image, explicit: true))
        XCTAssertFalse(policy.allows(.emoji, explicit: false))
    }

    func testGifvRoutingKeepsPosterAndExternalTargetSeparate() throws {
        let embed = try JSONDecoder().decode(Embed.self, from: JSONSerialization.data(withJSONObject: [
            "type": "gifv", "url": "https://example.com/external",
            "thumbnail": ["url": "mock://image/poster/32x24", "width": 32, "height": 24],
            "video": ["url": try fixture("loop-with-audio", "mp4").absoluteString, "width": 32, "height": 24]
        ]))
        let image = try XCTUnwrap(MessageBuilder.renderEmbed(embed, context: context)?.image)
        XCTAssertEqual(image.loopVideoURL, try fixture("loop-with-audio", "mp4"))
        XCTAssertEqual(image.openURL.absoluteString, "https://example.com/external")
        XCTAssertEqual(image.url.absoluteString, "mock://image/poster/32x24")
        let ordinary = Embed(type: "video", title: "normal", thumbnail: embed.thumbnail, video: embed.video)
        XCTAssertNil(MessageBuilder.renderEmbed(ordinary, context: context)?.image?.loopVideoURL)
        let posterless = Embed(type: "gifv", url: embed.url, video: embed.video)
        let withoutPoster = try XCTUnwrap(MessageBuilder.renderEmbed(posterless, context: context)?.image)
        XCTAssertFalse(withoutPoster.hasPoster)
        XCTAssertEqual(withoutPoster.loopVideoURL, image.loopVideoURL)
        XCTAssertEqual(withoutPoster.openURL, image.openURL)
    }

    func testMockRasterEmojiAvatarsStickersAndGifvUseOfflineSources() throws {
        let fixtures = MockDiscord.animatedMediaFixtures()
        let inputs = MessageBuilder.Inputs(name: "Aurora", color: .white, mentioned: false, replyName: nil, replyColor: nil)
        let rendered = fixtures.map { MessageBuilder.build($0, previous: nil, inputs: inputs, context: context, sendState: nil) }
        XCTAssertEqual(rendered.count, 4)
        XCTAssertEqual(rendered[0].media.first?.url.scheme, "mock")
        XCTAssertEqual(rendered[0].avatarURL?.absoluteString, "mock://animation/pulse.gif")
        XCTAssertEqual(rendered[0].reactions.first?.emoji.url(size: 32)?.absoluteString, "mock://animation/pulse.gif")
        XCTAssertTrue(rendered[1].embeds.first?.image?.loopVideoURL?.isFileURL == true)
        XCTAssertEqual(rendered[2].media.first?.url.absoluteString, "mock://animation/pulse.png")
        XCTAssertTrue(rendered[3].media.first?.isSpoiler == true)
        XCTAssertNil(StickerItem(id: 100, name: "Lottie", formatType: 3).rasterURL)
        let live = Emoji(id: 123_456_789_000_000_000, name: "pulse", animated: true)
        XCTAssertEqual(live.url(size: 32)?.pathExtension, "gif")
        let staticEmoji = Emoji(id: live.id, name: "still", animated: false)
        XCTAssertEqual(staticEmoji.url(size: 32)?.pathExtension, "webp")
    }

    func testBoundedDecoderMeasurementOnSyntheticFixtures() async throws {
        let data = try Data(contentsOf: fixture("pulse", "gif"))
        let result = await Task.detached {
            let start = CACurrentMediaTime()
            var decoded = 0, cost = 0
            for _ in 0..<30 {
                if let asset = RasterDecoder.decode(data, pixelSize: 96, scale: 1, animate: true) {
                    decoded += asset.frames.count
                    cost = max(cost, asset.byteCost)
                }
            }
            return (CACurrentMediaTime() - start, decoded, cost, Self.onMainThread())
        }.value
        XCTAssertEqual(result.1, 90)
        XCTAssertFalse(result.3)
        print("BATCH4B_SYNTHETIC_DECODE iterations=30 frames=\(result.1) elapsed_seconds=\(result.0) peak_asset_bytes=\(result.2) encoded_bytes=\(data.count) off_main=\(!result.3)")
    }

    nonisolated private static func onMainThread() -> Bool { Thread.isMainThread }

    func testNativeGifvLoopStripsAudioAndOwnsTeardown() async throws {
        let url = try fixture("loop-with-audio", "mp4")
        let original = AVURLAsset(url: url)
        let audio = try await original.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty, "Fixture deliberately contains audio")
        let item = try await InlineVideoPlayback.videoItem(url)
        let stripped = try await item.asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(stripped.isEmpty)
        let ready = expectation(description: "native loop prepared")
        let audioSession = AVAudioSession.sharedInstance()
        let category = audioSession.category
        let mode = audioSession.mode
        let options = audioSession.categoryOptions
        let video = InlineVideoPlayback()
        video.onChange = { if video.player != nil { ready.fulfill(); video.onChange = nil } }
        video.play(url)
        await fulfillment(of: [ready], timeout: 10)
        let player = try XCTUnwrap(video.player)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.volume, 0)
        XCTAssertNotNil(video.looper)
        XCTAssertTrue(video.layer.player === player)
        video.stop()
        XCTAssertNil(video.player)
        XCTAssertNil(video.looper)
        XCTAssertNil(video.layer.player)
        XCTAssertTrue(player.items().isEmpty)
        XCTAssertEqual(audioSession.category, category)
        XCTAssertEqual(audioSession.mode, mode)
        XCTAssertEqual(audioSession.categoryOptions, options)
        video.play(url)
        video.stop()
        // A completion from the cancelled preparation must not resurrect it.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(video.player)
        XCTAssertFalse(video.hasWork)
    }

    func testGifvSpoilerInactiveAndReuseCancelPendingNativePreparation() async throws {
        let media = MediaView(frame: CGRect(x: 0, y: 0, width: 120, height: 90))
        let item = MediaItem(url: try fixture("still", "png"), openURL: URL(string: "https://example.com/external")!,
                             width: 32, height: 24, isVideo: true, isSpoiler: true, alt: "secret",
                             loopVideoURL: try fixture("loop-with-audio", "mp4"))
        media.configure(item)
        let normal = MediaPlaybackPolicy(autoplayGIFs: true, animateEmoji: true, reduceMotion: false)
        media.mediaTick(time: 0, visible: true, granted: true, policy: normal)
        XCTAssertFalse(media.video.hasWork)
        media.reveal()
        media.mediaTick(time: 1, visible: true, granted: true, policy: .init(autoplayGIFs: true, animateEmoji: true, reduceMotion: true))
        XCTAssertFalse(media.video.hasWork)
        media.mediaTick(time: 2, visible: true, granted: true, policy: normal)
        XCTAssertTrue(media.video.hasWork)
        media.mediaTick(time: 3, visible: false, granted: false, policy: normal)
        XCTAssertFalse(media.video.hasWork)
        media.resetPlayback()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(media.video.player)
        XCTAssertNil(media.item)
        XCTAssertNil(media.imageView.image)
    }

    private final class Probe: MediaPlaybackParticipant {
        let playbackView = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        let playbackCost = 8 * 1024 * 1024
        var usesVideoSlot = false
        var granted = false
        var visible = false
        func mediaTick(time: TimeInterval, visible: Bool, granted: Bool, policy: MediaPlaybackPolicy) {
            self.visible = visible; self.granted = granted
        }
    }
    func testSharedSchedulerBoundsAggregateAndRevokesOnInactive() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let scheduler = MediaPlaybackScheduler()
        let probes = (0..<20).map { _ in Probe() }
        for probe in probes { window.addSubview(probe.playbackView); scheduler.add(probe) }
        scheduler.tick(active: true)
        let granted = probes.filter(\.granted)
        XCTAssertFalse(granted.isEmpty)
        XCTAssertLessThan(granted.count, probes.count)
        XCTAssertLessThanOrEqual(granted.reduce(0) { $0 + $1.playbackCost }, 48 * 1024 * 1024)
        for probe in probes { probe.usesVideoSlot = true }
        scheduler.tick(active: true)
        XCTAssertEqual(probes.filter(\.granted).count, 2)
        scheduler.tick(active: false)
        XCTAssertTrue(probes.allSatisfy { !$0.granted && !$0.visible })
        for probe in probes { scheduler.remove(probe) }
        window.isHidden = true
    }
}
