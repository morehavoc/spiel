import Foundation

/// A thread-safe, order-preserving handoff from the audio thread into the session.
///
/// This exists to close a real ordering bug. The obvious way to get mic buffers into
/// an actor is `Task { await session.feed(samples) }` inside the tap callback — but
/// **`Task` ordering is not guaranteed**, so two buffers submitted in capture order
/// can execute out of order. That is the same defect `TranscriptAssembler` was written
/// to fix, reintroduced one level down at chunk granularity, and it would corrupt both
/// the VAD's sequential state and the order of samples inside a segment.
///
/// `AsyncStream.Continuation.yield` is thread-safe and preserves call order, so the tap
/// calls it **synchronously** — no Task, no actor hop on the audio thread — and exactly
/// one consumer drains it in order.
public final class AudioSink: @unchecked Sendable {
    private let continuation: AsyncStream<[Float]>.Continuation
    public let stream: AsyncStream<[Float]>

    public init() {
        var cont: AsyncStream<[Float]>.Continuation!
        // .unbounded: dropping mic audio under back-pressure would silently lose words.
        stream = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    /// Safe to call from the audio thread. Synchronous and allocation-light.
    public func submit(_ samples: [Float]) {
        continuation.yield(samples)
    }

    public func finish() {
        continuation.finish()
    }
}
