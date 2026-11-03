import AVFoundation

/// Keeps Duocord running after it leaves the screen, so the gateway connection
/// stays live and notifications keep arriving: an audio session that
/// mixes with other audio, fed silence. Uses the `audio` background mode,
/// which App Review would reject; this is for TestFlight and local installs.
final class BackgroundKeepAlive {
    private let engine = AVAudioEngine()
    private var running = false

    func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // Mixes with music and calls instead of interrupting them.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let format = engine.outputNode.inputFormat(forBus: 0)
            let silence = Self.makeSilence(format: format)
            engine.attach(silence)
            engine.connect(silence, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            try engine.start()
            running = true
        } catch {
            print("duocord keep-alive failed: \(error.localizedDescription)")
            stop()
        }
    }

    /// The render block runs on the real-time audio thread, never the main actor.
    private nonisolated static func makeSilence(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { isSilence, _, _, buffers in
            isSilence.pointee = true
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }

    func stop() {
        engine.stop()
        for node in engine.attachedNodes where node is AVAudioSourceNode {
            engine.detach(node)
        }
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
