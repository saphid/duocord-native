import ImageIO
import UIKit

extension Notification.Name {
    static let mediaPlaybackPreferencesChanged = Notification.Name("duocord.mediaPlaybackPreferencesChanged")
}

/// Immutable frames may be shared; a view's clock, pause state and request never are.
nonisolated struct RasterMedia: @unchecked Sendable {
    let poster: UIImage
    let frames: [UIImage]
    let durations: [TimeInterval]
    let byteCost: Int
    let isAnimated: Bool
    var duration: TimeInterval { durations.reduce(0, +) }

    func frame(at elapsed: TimeInterval) -> UIImage {
        guard !frames.isEmpty, duration > 0 else { return poster }
        var time = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        for (index, delay) in durations.enumerated() {
            if time < delay { return frames[index] }
            time -= delay
        }
        return frames[0]
    }
}

nonisolated enum RasterDecoder {
    static let encodedLimit = 16 * 1024 * 1024
    static let frameLimit = 120
    static let decodedLimit = 8 * 1024 * 1024
    static let dimensionLimit = 8192
    static let sourcePixelLimit = 32 * 1024 * 1024
    static let animationPixelLimit = 4 * 1024 * 1024

    /// ImageIO composites GIF/APNG/WebP frames. Unsupported formats remain a poster.
    /// Check metadata before decoding; never allocate the source's full-size frames.
    static func decode(_ data: Data, pixelSize: Int, scale: CGFloat, animate: Bool,
                       cancelled: () -> Bool = { false }) -> RasterMedia? {
        guard !cancelled(), data.count <= encodedLimit, scale.isFinite, scale > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let h = properties[kCGImagePropertyPixelHeight as String] as? Int,
              w > 0, h > 0, w <= dimensionLimit, h <= dimensionLimit,
              w * h <= sourcePixelLimit else { return nil }
        let count = CGImageSourceGetCount(source)
        let pixel = max(1, min(pixelSize, 1024))
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: pixel] as CFDictionary
        guard !cancelled(), let first = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let poster = UIImage(cgImage: first, scale: scale, orientation: .up)
        let posterCost = first.bytesPerRow * first.height
        let animated = count > 1
        func still() -> RasterMedia {
            RasterMedia(poster: poster, frames: [], durations: [], byteCost: posterCost, isAnimated: animated)
        }
        guard animate, animated, w * h <= animationPixelLimit, count <= frameLimit,
              posterCost <= decodedLimit / count, !cancelled() else { return still() }
        var frames = [poster]
        var delays = [delay(source, index: 0)]
        var cost = posterCost
        for index in 1..<count {
            guard !cancelled() else { return nil }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width > 0, height > 0, width <= dimensionLimit, height <= dimensionLimit,
                  width * height <= animationPixelLimit else { return still() }
            // Subsequent frames can have different metadata; the thumbnail cap
            // and actual row-byte accounting bound even malformed frame sizes.
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { return still() }
            let bytes = frame.bytesPerRow * frame.height
            guard bytes <= decodedLimit - cost else { return still() }
            cost += bytes
            frames.append(UIImage(cgImage: frame, scale: scale, orientation: .up))
            delays.append(delay(source, index: index))
        }
        return RasterMedia(poster: poster, frames: frames, durations: delays, byteCost: cost, isAnimated: true)
    }

    private static func delay(_ source: CGImageSource, index: Int) -> TimeInterval {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        // String keys also work on systems which don't expose WebP constants.
        for key in ["{GIF}", "{PNG}", "{WebP}"] {
            if let values = props[key] as? [String: Any] {
                let value = (values["UnclampedDelayTime"] ?? values["DelayTime"]) as? Double ?? 0.1
                return value.isFinite && value >= 0.02 ? min(value, 10) : 0.1
            }
        }
        return 0.1
    }
}

/// Thread-safe cancellation is checked during decode as well as before delivery.
nonisolated final class MediaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

/// Streaming input cap: a hostile Content-Length or chunked response cannot
/// accumulate an unbounded Data before ImageIO gets to inspect it.
nonisolated private final class MediaDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var bytes = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completion: ((Data?) -> Void)?
    private let cancellation: MediaCancellation

    init(url: URL, configuration: URLSessionConfiguration, cancellation: MediaCancellation, completion: @escaping (Data?) -> Void) {
        self.cancellation = cancellation
        self.completion = completion
        super.init()
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.dataTask(with: url)
        task?.resume()
    }

    func cancel() { cancellation.cancel(); task?.cancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler((200..<300).contains(status) && response.expectedContentLength <= RasterDecoder.encodedLimit
                          && !cancellation.isCancelled ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancellation.isCancelled, data.count <= RasterDecoder.encodedLimit - bytes.count else {
            bytes.removeAll(); dataTask.cancel(); return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = error == nil && !cancellation.isCancelled ? bytes : nil
        bytes.removeAll()
        let callback = completion
        completion = nil
        callback?(result)
        session.finishTasksAndInvalidate()
        self.session = nil
        // Assigned once before resume; keep the completed task reference until
        // this download is released so main-thread cancel never races a write.
    }
}

/// Coalesced requests, four work slots, one decode queue and a cost-limited
/// immutable cache. Cancelling the last consumer cancels download and decode.
final class RasterMediaLoader {
    static let shared = RasterMediaLoader()
    nonisolated struct Key: Hashable, Sendable {
        let url: URL
        let pixelSize: Int
        let scale: CGFloat
        let animate: Bool
        var cacheKey: NSString { "\(url.absoluteString)#\(pixelSize)@\(scale)#\(animate)" as NSString }
    }
    private final class Entry {
        let id = UUID()
        let key: Key
        let cancellation = MediaCancellation()
        var callbacks: [UUID: (RasterMedia?) -> Void] = [:]
        var download: MediaDownload?
        var started = false
        init(_ key: Key) { self.key = key }
    }
    private let cache = NSCache<NSString, Box>()
    private final class Box { let media: RasterMedia; init(_ media: RasterMedia) { self.media = media } }
    private let queue = DispatchQueue(label: "duocord.media.decode", qos: .userInitiated)
    private let configuration: URLSessionConfiguration
    private var entries: [Key: Entry] = [:]
    private var pending: [Key] = []
    private var running = 0
    private(set) var requestCount = 0
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.default
        if configuration == nil {
            config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024,
                                       directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("RasterMedia"))
            config.requestCachePolicy = .returnCacheDataElseLoad
            config.urlCredentialStorage = nil
            config.httpCookieStorage = nil
        }
        self.configuration = config
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 128
    }

    @discardableResult
    /// Nil means deferred admission, with no callback or retained subscription.
    /// Visible surfaces retry on their shared clock; terminal failures call back nil.
    func load(_ key: Key, completion: @escaping (RasterMedia?) -> Void) -> (() -> Void)? {
        let token = UUID()
        let gate = MediaCancellation()
        let deliver: (RasterMedia?) -> Void = { media in if !gate.isCancelled { completion(media) } }
        if let cached = cache.object(forKey: key.cacheKey)?.media {
            // Always asynchronous: callers can install their generation/token first.
            DispatchQueue.main.async { deliver(cached) }
            return { gate.cancel() }
        }
        if let entry = entries[key] {
            entry.callbacks[token] = deliver
        } else if entries.count < 48 {
            let entry = Entry(key)
            entry.callbacks[token] = deliver
            entries[key] = entry
            pending.append(key)
            startPending()
        } else {
            return nil
        }
        return { [weak self] in
            gate.cancel()
            guard let self, let entry = self.entries[key] else { return }
            entry.callbacks[token] = nil
            if entry.callbacks.isEmpty {
                entry.cancellation.cancel()
                entry.download?.cancel()
                if !entry.started {
                    self.entries[key] = nil
                    self.pending.removeAll { $0 == key }
                }
            }
        }
    }

    private func startPending() {
        while running < 4, !pending.isEmpty {
            let key = pending.removeFirst()
            guard let entry = entries[key] else { continue }
            entry.started = true
            running += 1
            requestCount += 1
            let decode: (Data?) -> Void = { [weak self, weak entry] data in
                guard let self, let entry else { return }
                self.queue.async {
                    let media: RasterMedia?
                    if key.url.scheme == "mock", key.url.host != "animation" {
                        let dimensions = key.url.lastPathComponent.split(separator: "x").compactMap { Double($0) }
                        let ratio = dimensions.count == 2 && dimensions[0] > 0 && dimensions[1] > 0 ? dimensions[0] / dimensions[1] : 1
                        let side = CGFloat(min(1024, max(1, key.pixelSize)))
                        let size = ratio > 1 ? CGSize(width: side, height: max(1, side / ratio)) : CGSize(width: max(1, side * ratio), height: side)
                        let image = MockImages.image(for: key.url, pointSize: size, scale: 1)
                        media = image.map { RasterMedia(poster: $0, frames: [], durations: [], byteCost: Int(size.width * size.height * 4), isAnimated: false) }
                    } else {
                        media = data.flatMap { RasterDecoder.decode($0, pixelSize: key.pixelSize, scale: key.scale,
                                                                    animate: key.animate, cancelled: { entry.cancellation.isCancelled }) }
                    }
                    DispatchQueue.main.async { self.finish(entry, media: media) }
                }
            }
            if key.url.isFileURL || key.url.scheme == "mock" {
                queue.async {
                    let url = key.url.scheme == "mock" ? Bundle.main.url(forResource: key.url.lastPathComponent, withExtension: nil) : key.url
                    let length = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
                    let data = length <= RasterDecoder.encodedLimit ? url.flatMap { try? Data(contentsOf: $0) } : nil
                    DispatchQueue.main.async { decode(data) }
                }
            } else if key.url.scheme == "https" || key.url.scheme == "http" {
                entry.download = MediaDownload(url: key.url, configuration: configuration, cancellation: entry.cancellation) { data in
                    DispatchQueue.main.async { decode(data) }
                }
            } else { decode(nil) }
        }
    }

    private func finish(_ entry: Entry, media: RasterMedia?) {
        guard entries[entry.key] === entry else { return }
        entries[entry.key] = nil
        running -= 1
        if !entry.cancellation.isCancelled {
            if let media { cache.setObject(Box(media), forKey: entry.key.cacheKey, cost: media.byteCost) }
            entry.callbacks.values.forEach { $0(media) }
        } else if !entry.callbacks.isEmpty {
            // A new consumer may arrive while the cancelled decode is finishing.
            // Keep its original token: its cancellation closure looks up this key
            // and must still own the replacement transport/decode subscription.
            let replacement = Entry(entry.key)
            replacement.callbacks = entry.callbacks
            entries[entry.key] = replacement
            pending.append(entry.key)
        }
        startPending()
    }
    func clearMemory() { cache.removeAllObjects() }
}

enum MediaKind { case image, emoji, avatar }

struct MediaPlaybackPolicy {
    var autoplayGIFs: Bool
    var animateEmoji: Bool
    var reduceMotion: Bool
    func allows(_ kind: MediaKind, explicit: Bool?) -> Bool {
        explicit ?? (!reduceMotion && (kind == .emoji ? animateEmoji : autoplayGIFs))
    }
    static var current: Self {
        let defaults = UserDefaults.standard
        return Self(autoplayGIFs: defaults.object(forKey: "autoplayGIFs") as? Bool ?? true,
                    animateEmoji: defaults.object(forKey: "animateEmoji") as? Bool ?? true,
                    reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }
}

/// Geometry is checked against every clipping/hidden ancestor, not just window
/// attachment. This also handles pooled cells, scroll clipping and hidden panels.
enum MediaVisibility {
    static func isVisible(_ view: UIView) -> Bool {
        guard let window = view.window, !window.isHidden, !view.bounds.isEmpty else { return false }
        var visible = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01 else { return false }
            if current.clipsToBounds { visible = visible.intersection(current.convert(current.bounds, to: window)) }
            guard !visible.isNull, !visible.isEmpty else { return false }
            ancestor = current.superview
        }
        // UIKit can leave the underlying navigation page attached during a
        // presentation. Full-screen covers must not keep it playing.
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController {
                if let navigation = controller.navigationController, let page = navigation.visibleViewController {
                    var parent: UIViewController? = controller
                    while parent != nil && parent !== page { parent = parent?.parent }
                    if parent == nil { return false }
                }
                if let presented = controller.presentedViewController,
                   [.fullScreen, .overFullScreen].contains(presented.modalPresentationStyle) { return false }
            }
            responder = current.next
        }
        return true
    }
}

protocol MediaPlaybackParticipant: AnyObject {
    var playbackView: UIView { get }
    var playbackCost: Int { get }
    var usesVideoSlot: Bool { get }
    func mediaPolicyChanged()
    func mediaTick(time: TimeInterval, visible: Bool, granted: Bool, policy: MediaPlaybackPolicy)
}

extension MediaPlaybackParticipant {
    func mediaPolicyChanged() {}
}

/// One clock, at most 12 raster players (48 MiB reserved) and two muted video
/// players. Weak membership scales with existing UI surfaces; only the first
/// 256 can compete for animation. Overflow keeps posters and is promoted when
/// earlier surfaces leave. Never retains a reused view or touches audio.
final class MediaPlaybackScheduler {
    static let shared = MediaPlaybackScheduler()
    private final class Weak {
        weak var value: (any MediaPlaybackParticipant)?
        init(_ value: any MediaPlaybackParticipant) { self.value = value }
    }
    private var members: [Weak] = []
    private var clock: CADisplayLink?
    private var notifications: [NSObjectProtocol] = []
    init() {
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification, Notification.Name.mediaPlaybackPreferencesChanged] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == UIAccessibility.reduceMotionStatusDidChangeNotification || note.name == .mediaPlaybackPreferencesChanged {
                        for member in self?.members.compactMap(\.value) ?? [] { member.mediaPolicyChanged() }
                    }
                    self?.tick(active: note.name == UIApplication.willResignActiveNotification ? false : UIApplication.shared.applicationState == .active)
                }
            })
        }
    }
    deinit { for observer in notifications { NotificationCenter.default.removeObserver(observer) } }
    func add(_ member: any MediaPlaybackParticipant) {
        members.removeAll { $0.value == nil }
        guard !members.contains(where: { $0.value === member }) else { return }
        members.append(Weak(member))
        if clock == nil {
            let link = CADisplayLink(target: self, selector: #selector(frame))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            clock = link
        }
    }
    func remove(_ member: any MediaPlaybackParticipant) {
        members.removeAll { $0.value == nil || $0.value === member }
        if members.isEmpty { clock?.invalidate(); clock = nil }
    }
    @objc private func frame() { tick(active: UIApplication.shared.applicationState == .active) }
    func tick(active: Bool, time: TimeInterval = CACurrentMediaTime(), policy: MediaPlaybackPolicy = .current) {
        members.removeAll { $0.value == nil }
        var rasters = 0, videos = 0, bytes = 0
        for (index, member) in members.compactMap(\.value).enumerated() {
            let visible = active && MediaVisibility.isVisible(member.playbackView)
            let cost = member.playbackCost
            let granted = visible && index < 256 && (cost == 0 || (member.usesVideoSlot ? videos < 2 : rasters < 12 && bytes + cost <= 48 * 1024 * 1024))
            if granted && cost > 0 {
                if member.usesVideoSlot { videos += 1 } else { rasters += 1; bytes += cost }
            }
            member.mediaTick(time: time, visible: visible, granted: granted, policy: policy)
        }
        clock?.isPaused = !active
        if members.isEmpty { clock?.invalidate(); clock = nil }
    }
}
