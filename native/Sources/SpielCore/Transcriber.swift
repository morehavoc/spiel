import Foundation

/// A chunk of finalized transcript, tagged with the index of the speech segment
/// it came from.
///
/// The `index` is load-bearing. The Electron app appended transcription results in
/// *completion* order, so two segments in flight where the first was slower came back
/// with the sentences swapped. Every transcriber here emits an index and the
/// `TranscriptAssembler` reorders on it.
public struct TranscriptSegment: Sendable, Equatable {
    public let index: Int
    public let text: String
    public let isFinal: Bool

    public init(index: Int, text: String, isFinal: Bool) {
        self.index = index
        self.text = text
        self.isFinal = isFinal
    }
}

public struct TranscriptionTiming: Sendable {
    public let audioSeconds: Double
    public let wallSeconds: Double
    public var realtimeFactor: Double {
        wallSeconds > 0 ? audioSeconds / wallSeconds : 0
    }
    public init(audioSeconds: Double, wallSeconds: Double) {
        self.audioSeconds = audioSeconds
        self.wallSeconds = wallSeconds
    }
}

public struct TranscriptionResult: Sendable {
    public let text: String
    public let timing: TranscriptionTiming
    public init(text: String, timing: TranscriptionTiming) {
        self.text = text
        self.timing = timing
    }
}

public enum TranscriberKind: String, Sendable, CaseIterable {
    case parakeet
    case appleSpeech
}

/// Anything that can turn 16 kHz mono float samples into text.
///
/// Deliberately narrow: the engines differ enormously in how they stream, but every
/// one of them can answer "here are samples, give me text". Streaming lives one layer
/// up in `DictationSession`, so swapping engines cannot change dictation behaviour.
public protocol Transcriber: Sendable {
    var kind: TranscriberKind { get }
    /// Must be called before `transcribe`. May download models.
    func prepare() async throws
    /// `samples` are 16 kHz mono, normalized -1...1.
    func transcribe(samples: [Float]) async throws -> String
}

public enum TranscriberError: Error, CustomStringConvertible {
    case notPrepared(String)
    case unavailable(String)
    case failed(String)

    public var description: String {
        switch self {
        case .notPrepared(let s): return "transcriber not prepared: \(s)"
        case .unavailable(let s): return "transcriber unavailable: \(s)"
        case .failed(let s): return "transcription failed: \(s)"
        }
    }
}
