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
///
/// **It is re-armable, and that is load-bearing.** An `AsyncStream` is one-shot: once
/// `finish()` is called, every later `yield` is silently discarded. The first build
/// created the stream once in `prepare()` and finished it at the end of the first
/// dictation — so the SECOND and every later dictation submitted its microphone audio
/// into a dead stream. The meter still moved (it is computed from the same buffers
/// before they reach the sink), the panel still said "Listening…", and nothing was
/// ever transcribed. `rearm()` gives each dictation a fresh stream; anything submitted
/// while no stream is armed is COUNTED in `droppedBuffers` rather than vanishing, so a
/// regression of this exact bug shows up as a number instead of as silence.
public final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var _droppedBuffers = 0

    public init() {}

    /// Buffers submitted while no stream was armed (i.e. after `finish()` and before
    /// the next `rearm()`). Nonzero during a dictation means audio is being lost.
    public var droppedBuffers: Int {
        lock.lock(); defer { lock.unlock() }
        return _droppedBuffers
    }

    public var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return continuation != nil
    }

    /// Creates a fresh stream and returns it for the (single) consumer to drain.
    /// Finishes any previous stream first, so an old consumer terminates.
    public func rearm() -> AsyncStream<[Float]> {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        var cont: AsyncStream<[Float]>.Continuation!
        // .unbounded: dropping mic audio under back-pressure would silently lose words.
        let stream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        _droppedBuffers = 0
        return stream
    }

    /// Safe to call from the audio thread. Synchronous and allocation-light.
    public func submit(_ samples: [Float]) {
        // Hold the lock only to read the current continuation; never across `yield`,
        // which takes the stream's own internal lock — keeps the audio thread's
        // critical section to a pointer copy.
        lock.lock()
        let cont = continuation
        if cont == nil { _droppedBuffers += 1 }
        lock.unlock()
        cont?.yield(samples)
    }

    /// Ends the current stream. The consumer's `for await` loop then completes once
    /// it has drained everything already queued.
    public func finish() {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }
}
