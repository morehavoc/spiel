import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import SpielCore

/// Listen's system audio (2.10): what the Mac is playing — the other people on a
/// call heard through headphones — captured with ScreenCaptureKit at 16 kHz mono,
/// Spiel's own audio excluded. Uses the Screen Recording permission Listen
/// screenshots already ask for.
///
/// The microphone stays the clock: each mic buffer takes the same number of
/// samples from this FIFO and adds them (`mix`). Missing system samples are
/// silence; a backlog past `maxBacklog` drops its oldest samples so the two
/// streams cannot drift apart by more than that.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let enabledKey = "listenSystemAudio"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.morehavoc.spiel.system-audio")
    private let lock = NSLock()
    private var fifo: [Float] = []
    private let maxBacklog = 16_000 / 2   // 0.5 s
    private(set) var isRunning = false
    /// Set when the stream stopped on its own (permission revoked, display gone).
    var onStopped: ((String) -> Void)?

    func start() async throws {
        guard !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCapture.Failure.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw ScreenCapture.Failure.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        // Video cannot be switched off; make it as cheap as it gets.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 10, timescale: 1)
        config.queueDepth = 3
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        clear()
        stream = s
        isRunning = true
        DiagnosticLog.write("system audio: capture started")
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        isRunning = false
        Task { try? await s.stopCapture() }
        clear()
        DiagnosticLog.write("system audio: capture stopped")
    }

    private func clear() { lock.lock(); fifo.removeAll(keepingCapacity: true); lock.unlock() }

    /// Adds the next `mic.count` system samples to `mic`, clamped to ±1.
    func mix(_ mic: [Float]) -> [Float] {
        lock.lock()
        let n = min(mic.count, fifo.count)
        guard n > 0 else { lock.unlock(); return mic }
        var out = mic
        for i in 0..<n { out[i] = max(-1, min(1, out[i] + fifo[i])) }
        fifo.removeFirst(n)
        lock.unlock()
        return out
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        var samples: [Float] = []
        try? sampleBuffer.withAudioBufferList { abl, _ in
            guard let first = abl.first, let data = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.bindMemory(to: Float.self, capacity: count)
            let channels = max(1, Int(first.mNumberChannels))
            if channels == 1 {
                samples = Array(UnsafeBufferPointer(start: p, count: count))
            } else {
                // Interleaved: average to mono.
                let frames = count / channels
                samples = (0..<frames).map { f in
                    var sum: Float = 0
                    for c in 0..<channels { sum += p[f * channels + c] }
                    return sum / Float(channels)
                }
            }
        }
        guard !samples.isEmpty else { return }
        lock.lock()
        fifo.append(contentsOf: samples)
        if fifo.count > maxBacklog { fifo.removeFirst(fifo.count - maxBacklog) }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DiagnosticLog.write("system audio: stream stopped: \(error.localizedDescription)")
        isRunning = false
        self.stream = nil
        onStopped?(error.localizedDescription)
    }
}
