import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

/// Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+).
///
/// Zero third-party dependency and no HuggingFace download -- the model is managed by
/// the OS through `AssetInventory`. On Argmax's M4 benchmark it measures 14.0% WER at
/// a 70x speed factor, which puts it mid-table: WhisperKit base.en is faster but less
/// accurate, WhisperKit small.en is more accurate but half the speed, and only
/// Parakeet beats it on both axes at once.
///
/// Its real weakness for this app is that it dropped the Custom Vocabulary feature
/// Apple's older API had -- which is exactly why `Glossary` is a separate stage that
/// runs downstream of whichever engine produced the text.
public final class AppleSpeechTranscriber: Transcriber, @unchecked Sendable {
    public let kind: TranscriberKind = .appleSpeech
    private let localeIdentifier: String
    private var prepared = false
    /// Resolved once in `prepare()`; `supportedLocale` is an async lookup and the
    /// answer cannot change while the process runs.
    private var resolvedLocale: Locale?

    public init(localeIdentifier: String = "en-US") {
        self.localeIdentifier = localeIdentifier
    }

    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    public func prepare() async throws {
        #if canImport(Speech)
        guard #available(macOS 26.0, *) else {
            throw TranscriberError.unavailable("SpeechAnalyzer requires macOS 26 or later")
        }
        let locale = Locale(identifier: localeIdentifier)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unavailable("locale \(localeIdentifier) not supported by SpeechTranscriber")
        }
        resolvedLocale = supported
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)

        // The model is NOT preinstalled. Ask the OS to fetch it and wait, otherwise
        // the first dictation silently returns nothing.
        let status = await AssetInventory.status(forModules: [module])
        if status != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        prepared = true
        #else
        throw TranscriberError.unavailable("Speech framework not available in this SDK")
        #endif
    }

    public func transcribe(samples: [Float]) async throws -> String {
        #if canImport(Speech)
        guard #available(macOS 26.0, *) else {
            throw TranscriberError.unavailable("SpeechAnalyzer requires macOS 26 or later")
        }
        guard prepared else { throw TranscriberError.notPrepared("call prepare() first") }
        guard !samples.isEmpty else { return "" }

        guard let supported = resolvedLocale else {
            throw TranscriberError.notPrepared("locale not resolved; call prepare() first")
        }
        let module = SpeechTranscriber(locale: supported, preset: .transcription)

        // Feed the analyzer in the format IT wants, not the format we happen to have.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module]
        ) else {
            throw TranscriberError.failed("no compatible audio format for SpeechAnalyzer")
        }

        let buffers = try Self.buffers(from: samples, converting16kTo: analyzerFormat)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])

        // Collect results concurrently with feeding, then finalize.
        let collector = Task { () -> String in
            var pieces: [String] = []
            do {
                for try await result in module.results {
                    let s = String(result.text.characters)
                    if !s.isEmpty { pieces.append(s) }
                }
            } catch {
                // A throw here after finalization is normal stream teardown; keep
                // whatever we already collected rather than losing the transcript.
            }
            return pieces.joined(separator: " ")
        }

        try await analyzer.start(inputSequence: stream)
        for buffer in buffers {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = await collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw TranscriberError.unavailable("Speech framework not available")
        #endif
    }

    /// Converts our canonical 16 kHz mono float samples into buffers in the
    /// analyzer's preferred format, chunked so no single buffer is enormous.
    static func buffers(
        from samples: [Float],
        converting16kTo target: AVAudioFormat
    ) throws -> [AVAudioPCMBuffer] {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw TranscriberError.failed("could not build source format") }

        let chunkFrames = 16_000 * 10  // 10 s per buffer
        var out: [AVAudioPCMBuffer] = []
        var offset = 0

        let needsConversion = sourceFormat.sampleRate != target.sampleRate
            || sourceFormat.commonFormat != target.commonFormat
            || sourceFormat.channelCount != target.channelCount
        let converter = needsConversion ? AVAudioConverter(from: sourceFormat, to: target) : nil
        if needsConversion && converter == nil {
            throw TranscriberError.failed("could not build converter to analyzer format")
        }

        while offset < samples.count {
            let count = min(chunkFrames, samples.count - offset)
            guard let src = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(count)
            ) else { throw TranscriberError.failed("buffer allocation failed") }
            src.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress, let dst = src.floatChannelData?[0] else { return }
                dst.update(from: base + offset, count: count)
            }

            if let converter {
                let ratio = target.sampleRate / sourceFormat.sampleRate
                let cap = AVAudioFrameCount(Double(count) * ratio) + 4096
                guard let dstBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else {
                    throw TranscriberError.failed("target buffer allocation failed")
                }
                var supplied = false
                var err: NSError?
                converter.convert(to: dstBuf, error: &err) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return src
                }
                if let err { throw TranscriberError.failed("conversion: \(err.localizedDescription)") }
                out.append(dstBuf)
            } else {
                out.append(src)
            }
            offset += count
        }
        return out
    }
}
