import AVFoundation
import Foundation

/// Microphone capture, converted to the 16 kHz mono float format every engine wants.
///
/// Note what this does NOT do: no WebM, no Opus, no MediaRecorder chunking, no
/// header splicing. The Electron app had to re-encode to a container and then prepend
/// the session's first 100 ms chunk to every later segment so the file would decode --
/// which shipped a duplicated fragment of the session opening on every segment and
/// left the timeline non-monotonic. Working in raw PCM makes the whole class of bug
/// impossible: a segment is just a slice of a Float array.
public final class AudioCapture: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let converterLock = NSLock()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var onSamples: (([Float]) -> Void)?
    private var configObserver: NSObjectProtocol?
    private(set) public var isRunning = false

    public init() {}

    // MARK: - Microphone permission and device identity
    //
    // Both exist because the first test build asked for the mic on the FIRST HOTKEY
    // PRESS: the TCC prompt appeared, the engine was already running, and that whole
    // dictation was spent staring at a dialog. Ask at launch instead, and be able to
    // say WHICH device we are listening to, because "the dots don't move" on a Mac
    // with several inputs is usually the wrong device, not a broken app.

    public enum MicrophoneAuthorization: String, Sendable {
        case authorized, denied, restricted, notDetermined
    }

    public static func microphoneAuthorization() -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Shows the system prompt if the state is `notDetermined`; otherwise returns the
    /// existing decision immediately.
    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// The system default input, as the user would see it in System Settings → Sound.
    public static func defaultInputDeviceName() -> String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "(no input device)"
    }

    public enum CaptureError: Error, CustomStringConvertible {
        case formatUnavailable
        case engineFailed(String)
        public var description: String {
            switch self {
            case .formatUnavailable: return "could not build a 16 kHz mono format"
            case .engineFailed(let s): return "audio engine failed: \(s)"
            }
        }
    }

    /// Starts the mic. `handler` is called on the audio thread with 16 kHz mono
    /// samples -- keep it cheap and non-blocking.
    ///
    /// `onRouteChange` fires on a private serial queue (NOT the main thread — hop
    /// if you touch UI) after the audio route changed mid-capture and capture was
    /// restarted on the new default input — with the device name on success, or the
    /// error text if the restart failed (capture is then stopped). Nil keeps the old
    /// behaviour of merely logging it.
    public func start(handler: @escaping ([Float]) -> Void,
                      onRouteChange: ((String) -> Void)? = nil) throws {
        try control.sync { try startLocked(handler: handler, onRouteChange: onRouteChange) }
    }

    /// Every start/stop/restart runs here, serially. The route-change notification
    /// arrives on an arbitrary thread, and a restart racing a `stop()` from the app
    /// would re-arm a capture the user just ended. Not the main queue: `spiel-cli`
    /// blocks its main thread on a semaphore, so a main-queue hop there never runs
    /// — which is exactly how the first version of this restart was found dead in a
    /// live test (capture stopped at the switch, 0 restarts).
    private let control = DispatchQueue(label: "com.morehavoc.spiel.audio-capture")

    private func startLocked(handler: @escaping ([Float]) -> Void,
                             onRouteChange: ((String) -> Void)?) throws {
        guard !isRunning else { return }
        onSamples = handler
        self.onRouteChange = onRouteChange
        try arm()

        // The engine STOPS ITSELF when the audio route changes mid-capture (AirPods
        // connect, a USB mic unplugs, the default input is switched, the Mac wakes
        // from sleep). Nothing else tells us: the tap simply stops firing and the
        // meter freezes. For a 14 s dictation that is a diagnosis; for an hour-long
        // Listen it is a silent death at the moment he puts AirPods in — so capture
        // is re-armed on the new input, and the caller is told which device it is.
        configObserver.map { NotificationCenter.default.removeObserver($0) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.control.async { self.restartAfterRouteChange() }
        }
        isRunning = true
    }

    private var onRouteChange: ((String) -> Void)?
    /// Restarts performed after a route change since `start()`.
    private(set) public var restarts = 0

    /// Tear down the tap and converter, re-read the input format (a USB mic at
    /// 48 kHz to a built-in at 44.1 kHz changes it), re-install and restart.
    private func restartAfterRouteChange() {
        guard isRunning else { return }
        let device = Self.defaultInputDeviceName()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        do {
            try arm()
            restarts += 1
            DiagnosticLog.write("audio engine configuration changed mid-capture — restarted capture on \(device)")
            onRouteChange?(device)
        } catch {
            isRunning = false
            converterLock.lock(); converter = nil; converterLock.unlock()
            DiagnosticLog.write("audio engine configuration changed mid-capture — restart FAILED: \(error); default input is now \(device)")
            onRouteChange?("could not restart capture on \(device): \(error)")
        }
    }

    /// The engine set-up shared by `start` and the route-change restart: read the
    /// input format, build the converter, install the tap, start the engine.
    private func arm() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // With NO input device (headless Mac, or every input disconnected) the node
        // reports 0 Hz / 0 channels, and `installTap` then raises an ObjC exception —
        // an app crash, not a thrown error. Refuse up front and say why.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.engineFailed(
                "no usable input device (format \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch) — is a microphone connected and selected in System Settings → Sound?"
            )
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw CaptureError.formatUnavailable }

        // The mic's native rate is typically 44.1/48 kHz; convert rather than asking
        // the hardware for 16 kHz, which many devices silently refuse. Rebuilt under
        // the lock on every arm because the audio thread may be inside `convert`.
        converterLock.lock()
        targetFormat = target
        converter = AVAudioConverter(from: inputFormat, to: target)
        converterLock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let out = self.convert(buffer) {
                self.onSamples?(out)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error.localizedDescription)
        }
    }

    public func stop() {
        control.sync { stopLocked() }
    }

    private func stopLocked() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        onSamples = nil
        onRouteChange = nil
        configObserver.map { NotificationCenter.default.removeObserver($0) }
        configObserver = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        converterLock.lock()
        defer { converterLock.unlock() }
        guard let converter, let targetFormat else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return nil }
        guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    /// Loads a WAV/AIFF/CAF file as 16 kHz mono float. Used by the CLI so
    /// transcription can be verified without touching the microphone or TCC.
    public static func loadFile(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw CaptureError.formatUnavailable }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw CaptureError.formatUnavailable
        }

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            throw CaptureError.formatUnavailable
        }

        var done = false
        var error: NSError?
        converter.convert(to: out, error: &error) { packets, status in
            if done {
                status.pointee = .endOfStream
                return nil
            }
            guard let scratch = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: packets
            ) else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: scratch)
            } catch {
                status.pointee = .endOfStream
                return nil
            }
            if scratch.frameLength == 0 {
                done = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return scratch
        }
        if let error { throw CaptureError.engineFailed(error.localizedDescription) }
        guard let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
