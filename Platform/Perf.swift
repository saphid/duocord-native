import QuartzCore
import UIKit
import os

/// Signposts for Instruments plus an in-app frame monitor, so performance
/// budgets can be checked from the simulator without a profiler attached.
/// Results append to Documents/perf.jsonl.
final class Perf {
    static let shared = Perf()
    static let signposter = OSSignposter(subsystem: "com.saphid.duocord.native", category: .pointsOfInterest)
    private let log = Logger(subsystem: "com.saphid.duocord.native", category: "perf")

    /// Process start (kernel record), so launch marks include pre-main time.
    let launchStart: TimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        // Convert wall-clock start to the uptime clock.
        return ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970 - started)
    }()
    private var marks: [String: TimeInterval] = [:]
    private var reported = Set<String>()

    // Frame monitoring
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var hitchTime: Double = 0
    private var worstFrame: Double = 0
    private var expected: Double = 1.0 / 60
    private var label = ""
    private var monitorStart: CFTimeInterval = 0

    /// Milliseconds since process start; launch budget marks.
    func sinceLaunch() -> Double { (ProcessInfo.processInfo.systemUptime - launchStart) * 1000 }

    func markOnce(_ name: String, extra: [String: Any] = [:]) {
        guard !reported.contains(name) else { return }
        reported.insert(name)
        var record = extra
        record["event"] = name
        record["ms"] = round(sinceLaunch())
        write(record)
    }

    func begin(_ name: String) { marks[name] = ProcessInfo.processInfo.systemUptime }

    @discardableResult
    func end(_ name: String, extra: [String: Any] = [:]) -> Double? {
        guard let start = marks.removeValue(forKey: name) else { return nil }
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var record = extra
        record["event"] = name
        record["ms"] = (ms * 10).rounded() / 10
        write(record)
        return ms
    }

    func record(_ event: String, _ fields: [String: Any]) {
        var record = fields
        record["event"] = event
        write(record)
    }

    // MARK: Frames

    func startFrames(_ label: String) {
        stopFrames()
        self.label = label
        frames = 0; hitches = 0; hitchTime = 0; worstFrame = 0; lastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        monitorStart = CACurrentMediaTime()
    }

    @discardableResult
    func stopFrames() -> [String: Any]? {
        guard let link else { return nil }
        link.invalidate()
        self.link = nil
        let duration = CACurrentMediaTime() - monitorStart
        let result: [String: Any] = [
            "label": label,
            "frames": frames,
            "seconds": (duration * 100).rounded() / 100,
            "refreshHz": Int((1 / expected).rounded()),
            "hitches": hitches,
            "hitchMs": (hitchTime * 1000 * 10).rounded() / 10,
            "hitchRatioMsPerS": duration > 0 ? (hitchTime * 1000 / duration * 10).rounded() / 10 : 0,
            "worstFrameMs": (worstFrame * 1000 * 10).rounded() / 10,
        ]
        record("frames", result)
        return result
    }

    @objc private func tick(_ link: CADisplayLink) {
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0 { expected = interval }
        if lastTimestamp > 0 {
            let delta = link.timestamp - lastTimestamp
            frames += 1
            worstFrame = max(worstFrame, delta)
            // A hitch: the frame arrived later than one refresh interval allows.
            if delta > expected * 1.5 {
                hitches += 1
                hitchTime += delta - expected
            }
        }
        lastTimestamp = link.timestamp
    }

    private func write(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        log.info("perf \(line, privacy: .public)")
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appending(path: "perf.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }
}
