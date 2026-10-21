import AVFoundation
import Foundation

/// iPhone microphone → 16 kHz mono Float32, handed to `DictationSession.sink`.
///
/// The Mac's `AudioCapture` is CoreAudio device enumeration and is not compiled
/// here; this one is the same contract (`sampleRate`, start/stop, a handler that
/// receives samples in capture order on the audio thread) on `AVAudioSession`.
public final class AudioCapture: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
    private(set) public var isRunning = false
    /// Whether the mic engine (not the debug file feed) is what's running. Touching
    /// `inputNode` initialises the hardware, so stop() must not do it for a feed.
    private var engineStarted = false

    public init() {}

    public enum CaptureError: Error, CustomStringConvertible {
        case noInput, converter, engine(String)
        public var description: String {
            switch self {
            case .noInput: return "the microphone delivered no audio format"
            case .converter: return "could not convert microphone audio to 16 kHz"
            case .engine(let s): return "the audio engine would not start: \(s)"
            }
        }
    }

    /// Name of the current input route ("iPhone Microphone", "AirPods Pro").
    public static var currentInputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iPhone microphone"
    }

    /// `.playAndRecord` + `.mixWithOthers` so Listen can run beside a call or a
    /// video app instead of interrupting it. No Bluetooth option: a meeting in a
    /// room is better heard by the phone's own mics than by AirPods in a pocket.
    public static func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try s.setActive(true)
    }

    public func start(handler: @escaping @Sendable ([Float]) -> Void) throws {
        try Self.configureSession()
        #if DEBUG
        if let path = Self.feedFile { try startFeed(path, handler: handler); return }
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        // Mono at the device rate first; the converter only resamples.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: mono, to: target) else { throw CaptureError.converter }
        converter = conv
        let target = self.target
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let monoBuf = Self.downmix(buffer, to: mono) else { return }
            let ratio = target.sampleRate / mono.sampleRate
            let cap = AVAudioFrameCount(Double(monoBuf.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return monoBuf
            }
            guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
            handler(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engine("\(error)")
        }
        isRunning = true
        engineStarted = true
    }

    #if DEBUG
    /// Debug builds only: `SPIEL_FEED_FILE=/path/audio.m4a` replaces the mic with a
    /// file played into the same handler at real time, so the whole Listen path
    /// (VAD → Parakeet → live document → autosave) runs in the simulator.
    private var feeder: Task<Void, Never>?
    static var feedFile: String? { ProcessInfo.processInfo.environment["SPIEL_FEED_FILE"] }

    private func startFeed(_ path: String, handler: @escaping @Sendable ([Float]) -> Void) throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let src = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)) else { throw CaptureError.noInput }
        try file.read(into: buf)
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.sampleRate, channels: 1, interleaved: false),
              let monoBuf = Self.downmix(buf, to: mono),
              let conv = AVAudioConverter(from: mono, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * 16_000 / src.sampleRate) + 64)
        else { throw CaptureError.converter }
        var fed = false
        conv.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return monoBuf
        }
        let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        isRunning = true
        feeder = Task.detached {
            let chunk = 1600  // 100 ms
            var i = 0
            while i < samples.count, !Task.isCancelled {
                handler(Array(samples[i..<min(i + chunk, samples.count)]))
                i += chunk
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Trailing silence so the last segment closes on its own.
            for _ in 0..<20 where !Task.isCancelled {
                handler([Float](repeating: 0, count: chunk))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    #endif

    public func stop() {
        #if DEBUG
        feeder?.cancel(); feeder = nil
        #endif
        guard isRunning else { return }
        if engineStarted {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engineStarted = false
        }
        isRunning = false
    }

    /// Average every channel into one. A copy, never in place: the tap's buffer
    /// belongs to the engine.
    static func downmix(_ buffer: AVAudioPCMBuffer, to mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        let n = Int(buffer.frameLength), chans = Int(buffer.format.channelCount)
        out.frameLength = buffer.frameLength
        if chans == 1 {
            dst[0].update(from: src[0], count: n)
        } else {
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<chans { sum += src[c][i] }
                dst[0][i] = sum / Float(chans)
            }
        }
        return out
    }
}
