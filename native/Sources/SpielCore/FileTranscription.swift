import AVFoundation
import CoreMedia
import Foundation

/// Reads any file AVFoundation can open — wav, aiff, caf, m4a, mp3, and the audio
/// track of mp4/mov — as 16 kHz mono float, streamed in chunks.
///
/// `AudioCapture.loadFile` (AVAudioFile) is what `spiel-cli` has always used, but
/// AVAudioFile does not open video containers; AVAssetReader does, and it resamples
/// to the output settings itself, so there is no converter to get wrong.
public enum AudioFileReader {

    public enum ReadError: Error, CustomStringConvertible {
        case missing(String)
        case noAudio(String)
        case unreadable(String)
        public var description: String {
            switch self {
            case .missing(let s): return "no such file: \(s)"
            case .noAudio(let s): return "no audio track in \(s)"
            case .unreadable(let s): return "cannot read audio: \(s)"
            }
        }
    }

    /// Returns the number of samples delivered. `chunk` is called in file order.
    @discardableResult
    public static func read(_ url: URL, chunk: ([Float]) -> Void) async throws -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ReadError.missing(url.path)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ReadError.unreadable("\(url.lastPathComponent): permission denied")
        }
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ReadError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let track = tracks.first else { throw ReadError.noAudio(url.lastPathComponent) }
        return try drain(asset: asset, track: track, name: url.lastPathComponent, chunk: chunk)
    }

    private static func drain(asset: AVAsset, track: AVAssetTrack, name: String, chunk: ([Float]) -> Void) throws -> Int {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ReadError.unreadable("\(name): \(error.localizedDescription)")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioCapture.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ReadError.unreadable("\(name): cannot decode this audio format") }
        reader.add(output)
        guard reader.startReading() else {
            throw ReadError.unreadable("\(name): \(reader.error?.localizedDescription ?? "decoder would not start")")
        }
        var total = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw ReadError.unreadable("\(name): block copy failed (\(status))") }
            total += count
            chunk(samples)
        }
        if reader.status == .failed {
            throw ReadError.unreadable("\(name): \(reader.error?.localizedDescription ?? "decode failed")")
        }
        return total
    }

    /// A file extension for audio arriving on stdin, from its first bytes. AVFoundation
    /// picks a parser by extension, so a temp file named `.bin` would fail to open.
    /// nil = not a container this recognises (the caller tries anyway and reports).
    public static func sniffExtension(_ head: Data) -> String? {
        let b = [UInt8](head.prefix(12))
        func ascii(_ r: Range<Int>) -> String? {
            guard b.count >= r.upperBound else { return nil }
            return String(bytes: b[r], encoding: .ascii)
        }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return "wav" }
        if ascii(0..<4) == "FORM", let t = ascii(8..<12), t == "AIFF" || t == "AIFC" { return "aiff" }
        if ascii(0..<4) == "caff" { return "caf" }
        if ascii(0..<4) == "fLaC" { return "flac" }
        if ascii(4..<8) == "ftyp" { return ascii(8..<12) == "qt  " ? "mov" : "mp4" }
        if ascii(0..<3) == "ID3" { return "mp3" }
        if b.count >= 2, b[0] == 0xFF, b[1] & 0xE0 == 0xE0 {
            // 0xFFF sync word: MPEG audio, or ADTS AAC when the layer bits are 00.
            return b[1] & 0x06 == 0 ? "aac" : "mp3"
        }
        return nil
    }
}

/// One stretch of speech with its place in the file, in seconds.
public struct TimedSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// A transcribed file, and every way `spiel transcribe` can print it.
public struct FileTranscript: Sendable, Equatable {
    public var file: String
    public var durationSeconds: Double
    public var engine: String
    public var segments: [TimedSegment]
    /// Segments the engine failed on (`segment 3: …`). Non-empty = partial.
    public var errors: [String]

    public init(file: String, durationSeconds: Double, engine: String, segments: [TimedSegment], errors: [String] = []) {
        self.file = file; self.durationSeconds = durationSeconds; self.engine = engine
        self.segments = segments; self.errors = errors
    }

    /// A pause this long starts a new paragraph — the same 2 s Listen splits on.
    public static let paragraphGap = 2.0

    /// Segments grouped into paragraphs by the pause between them.
    public var paragraphs: [[TimedSegment]] {
        var out: [[TimedSegment]] = []
        for s in segments where !s.text.isEmpty {
            if let prev = out.last?.last, s.start - prev.end < Self.paragraphGap {
                out[out.count - 1].append(s)
            } else {
                out.append([s])
            }
        }
        return out
    }

    /// Paragraphs separated by a blank line. `--format text` prints exactly this.
    public var text: String {
        paragraphs.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n\n")
    }

    public var words: Int { DictationHistory.wordCount(text) }

    public enum Format: String, CaseIterable, Sendable {
        case text, md, srt, vtt, json
        public var fileExtension: String { self == .text ? "txt" : rawValue }
    }

    public func render(_ format: Format) -> String {
        switch format {
        case .text: return text.isEmpty ? "" : text + "\n"
        case .md: return markdown()
        case .srt: return subtitles(vtt: false)
        case .vtt: return subtitles(vtt: true)
        case .json: return json()
        }
    }

    /// `HH:MM:SS,mmm` (SRT) or `HH:MM:SS.mmm` (WebVTT).
    public static func timestamp(_ seconds: Double, vtt: Bool) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60,
                      vtt ? "." : ",", ms % 1000)
    }

    private func subtitles(vtt: Bool) -> String {
        var out = vtt ? "WEBVTT\n\n" : ""
        var n = 0
        for s in segments where !s.text.isEmpty {
            n += 1
            // A cue must have positive length; a segment the VAD closed inside one
            // frame would otherwise read start == end.
            let end = max(s.end, s.start + 0.5)
            if !vtt { out += "\(n)\n" }
            out += "\(Self.timestamp(s.start, vtt: vtt)) --> \(Self.timestamp(end, vtt: vtt))\n\(s.text)\n\n"
        }
        return out
    }

    /// Same shape as a Listen transcript: YAML frontmatter, then `[MM:SS]` paragraphs.
    private func markdown() -> String {
        var out = "---\n"
        out += "app: Spiel\n"
        out += "spiel_version: \(SpielVersion.short)\n"
        out += "kind: transcript\n"
        out += "title: \(TranscriptDocument.yaml(file))\n"
        out += "duration_s: \(Int(durationSeconds.rounded()))\n"
        out += "words: \(words)\n"
        out += "source: file\n"
        out += "engine: \(TranscriptDocument.yaml(engine))\n"
        out += "---\n\n"
        for p in paragraphs {
            out += "[\(TranscriptDocument.formatOffset(p[0].start))] " + p.map(\.text).joined(separator: " ") + "\n\n"
        }
        if !errors.isEmpty {
            out += "[\(errors.count) segment\(errors.count == 1 ? "" : "s") could not be transcribed]\n"
        }
        return out
    }

    /// One JSON object, pretty-printed, keys in the documented order (JSONEncoder
    /// does not keep declaration order, and an agent reading the output by eye
    /// should see `file` first). Segments are one object per line.
    public func json() -> String { Self.json([self], asArray: false) }

    /// Several files → a JSON array of the same objects.
    public static func json(_ ts: [FileTranscript], asArray: Bool) -> String {
        let objects = ts.map { $0.jsonObject(indent: asArray ? "  " : "") }
        if asArray || ts.count != 1 {
            return objects.isEmpty ? "[]\n" : "[\n" + objects.map { "  " + $0 }.joined(separator: ",\n") + "\n]\n"
        }
        return objects[0] + "\n"
    }

    static func jsonString(_ s: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return (try? enc.encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// Milliseconds, printed without float noise (`8.704`, not `8.7040000001`).
    static func jsonNumber(_ x: Double) -> String {
        let ms = Int((x * 1000).rounded())
        return ms % 1000 == 0 ? "\(ms / 1000)" : String(format: "%.3f", Double(ms) / 1000)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    private func jsonObject(indent: String) -> String {
        let i = indent + "  "
        var lines: [String] = []
        lines.append("\(i)\"file\": \(Self.jsonString(file))")
        lines.append("\(i)\"duration_s\": \(Self.jsonNumber(durationSeconds))")
        lines.append("\(i)\"engine\": \(Self.jsonString(engine))")
        lines.append("\(i)\"words\": \(words)")
        let segs = segments.filter { !$0.text.isEmpty }.map {
            "\(i)  {\"start\": \(Self.jsonNumber($0.start)), \"end\": \(Self.jsonNumber($0.end)), \"text\": \(Self.jsonString($0.text))}"
        }
        lines.append("\(i)\"segments\": " + (segs.isEmpty ? "[]" : "[\n" + segs.joined(separator: ",\n") + "\n\(i)]"))
        lines.append("\(i)\"text\": \(Self.jsonString(text))")
        lines.append("\(i)\"errors\": [" + errors.map(Self.jsonString).joined(separator: ", ") + "]")
        return "{\n" + lines.joined(separator: ",\n") + "\n\(indent)}"
    }
}

/// Feeds a file through the real dictation pipeline — Silero VAD, the 14 s
/// segmenter, the engine, the assembler and the glossary — exactly as `spiel-cli
/// replay` does, so a file of any length transcribes the way the app would hear it.
/// (One engine call on a whole file is limited to 15 s by FluidAudio's single-chunk
/// path; see `DictationSession.Config.maxSegmentDuration`.)
public enum FileTranscriber {

    /// Collects the session's timed releases; events arrive from segment tasks.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var segments: [TimedSegment] = []
        private var errors: [String] = []
        func add(_ s: TimedSegment) { lock.lock(); segments.append(s); lock.unlock() }
        func fail(_ e: String) { lock.lock(); errors.append(e); lock.unlock() }
        var snapshot: ([TimedSegment], [String]) { lock.lock(); defer { lock.unlock() }; return (segments, errors) }
    }

    public struct Outcome: Sendable {
        public var transcript: FileTranscript
        /// `DictationSession.Report.diagnosis` — why a transcript is empty, if it is.
        public var diagnosis: String
        public var peak: Float
    }

    /// `progress(doneSeconds, totalSeconds)` fires as each segment lands.
    public static func run(_ url: URL, displayName: String, engine: String, session: DictationSession,
                           progress: (@Sendable (Double, Double) -> Void)? = nil) async throws -> Outcome {
        await session.reset()
        let box = Box()
        let total = Box2()
        await session.setEventHandler { event in
            switch event {
            case .textReleased(let t, let start, _, let end):
                box.add(TimedSegment(start: start, end: end, text: t))
                progress?(end, total.value)
            case .error(let e, _, _):
                box.fail(e)
            default: break
            }
        }
        let samples = try await AudioFileReader.read(url) { session.sink.submit($0) }
        total.value = Double(samples) / AudioCapture.sampleRate
        let report = await session.finishWithReport()
        let (segments, errors) = box.snapshot
        let t = FileTranscript(file: displayName, durationSeconds: Double(samples) / AudioCapture.sampleRate,
                               engine: engine, segments: segments.sorted { $0.start < $1.start },
                               errors: errors.isEmpty ? report.errors : errors)
        return Outcome(transcript: t, diagnosis: fileDiagnosis(audioSeconds: report.audioSeconds, peak: report.peak,
                                                              segments: report.segments, errors: report.errors),
                       peak: report.peak)
    }

    /// Why a file produced no text. `Report.diagnosis` is written for the live mic
    /// ("the mic is muted, the wrong input device…"), which is the wrong advice for
    /// a file that is simply silent.
    public static func fileDiagnosis(audioSeconds: Double, peak: Float, segments: Int, errors: [String]) -> String {
        let secs = String(format: "%.1f s", audioSeconds)
        if audioSeconds == 0 { return "the file holds no audio samples" }
        if peak < 0.005 { return "\(secs) of silence (peak \(String(format: "%.4f", peak)))" }
        if segments == 0 { return "\(secs) of sound (peak \(String(format: "%.2f", peak))) but nothing the voice detector judged speech" }
        if !errors.isEmpty { return "the engine failed on every segment: \(errors.joined(separator: "; "))" }
        return "\(segments) stretch\(segments == 1 ? "" : "es") of speech detected, but the engine returned no words"
    }

    private final class Box2: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Double = 0
        var value: Double {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }
}
