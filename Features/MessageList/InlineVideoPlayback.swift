import AVFoundation
import UIKit

/// Only gifv gets a native loop. A video-only composition prevents even an
/// unexpectedly audio-bearing gifv from acquiring an audible playback path.
final class InlineVideoPlayback {
    let layer = AVPlayerLayer()
    private(set) var player: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?
    private(set) var generation = 0
    private var task: Task<Void, Never>?
    private var url: URL?
    private var failedURL: URL?
    private var failureObservation: NSKeyValueObservation?
    var onChange: (() -> Void)?
    var isPlaying: Bool { player != nil }
    var hasWork: Bool { url != nil }
    var failed: Bool { failedURL != nil }

    static func videoItem(_ url: URL) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            try await prepare(asset)
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func prepare(_ asset: AVURLAsset) async throws -> AVPlayerItem {
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= 120,
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.unsupported }
        let size = try await track.load(.naturalSize)
        guard size.width > 0, size.height > 0, size.width <= 8192, size.height <= 8192 else { throw MediaError.unsupported }
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaError.unsupported
        }
        try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        target.preferredTransform = try await track.load(.preferredTransform)
        let item = AVPlayerItem(asset: composition)
        item.preferredForwardBufferDuration = 2
        item.preferredPeakBitRate = 2_000_000
        item.preferredMaximumResolution = CGSize(width: 1024, height: 1024)
        return item
    }
    enum MediaError: Error { case unsupported }

    func play(_ url: URL) {
        guard self.url != url, failedURL != url else { return }
        stop()
        self.url = url
        let current = generation
        task = Task { [weak self] in
            do {
                let item = try await Self.videoItem(url)
                try Task.checkCancellation()
                guard let self, self.generation == current, self.url == url else { return }
                let player = AVQueuePlayer()
                player.isMuted = true
                player.volume = 0
                player.audiovisualBackgroundPlaybackPolicy = .pauses
                player.preventsDisplaySleepDuringVideoPlayback = false
                self.player = player
                self.looper = AVPlayerLooper(player: player, templateItem: item)
                self.failureObservation = self.looper?.observe(\.status, options: [.new]) { [weak self] looper, _ in
                    guard looper.status == .failed else { return }
                    DispatchQueue.main.async {
                        guard let self, self.generation == current else { return }
                        self.failedURL = url
                        self.stop()
                    }
                }
                self.layer.videoGravity = .resizeAspectFill
                self.layer.player = player
                player.play()
                self.onChange?()
            } catch {
                guard let self, self.generation == current else { return }
                self.failedURL = url
                self.url = nil
                self.onChange?()
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel(); task = nil
        failureObservation = nil
        looper?.disableLooping(); looper = nil
        player?.pause()
        player?.removeAllItems()
        layer.player = nil
        player = nil
        url = nil
        onChange?()
    }
    func reset() { stop(); failedURL = nil }
    deinit { task?.cancel() }
}
