import AVFoundation
import Foundation

/// Keeps the meeting's audio when he asks for it: the same 16 kHz mono samples the
/// transcriber hears, written as AAC (.m4a, ~32 kbit/s ≈ 14 MB an hour) beside the
/// transcript. Writes happen on its own serial queue, never on the audio thread.
final class AudioRecorder: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.morehavoc.spiel.recorder")
    private var file: AVAudioFile?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private(set) var error: String?

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Safe from any thread; order is preserved by the serial queue.
    func append(_ samples: [Float]) {
        queue.async { [self] in
            guard let file, !samples.isEmpty,
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            do { try file.write(from: buf) } catch {
                self.error = "\(error)"
                self.file = nil
            }
        }
    }

    /// Closes the file (AVAudioFile finalises on release). Waits for queued writes.
    func finish() {
        queue.sync { file = nil }
    }
}
