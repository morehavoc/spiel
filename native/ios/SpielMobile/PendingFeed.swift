import Foundation

/// Lets a meeting start before the speech model is ready (0.5). Until a sink is
/// attached, mic samples and pause notes queue here in capture order; `attach`
/// replays them into the session and then switches to passing samples straight
/// through. Called from the audio thread (`submit`) and the main actor.
final class PendingFeed: @unchecked Sendable {
    enum Item { case samples([Float]), pause(TimeInterval) }

    /// 15 minutes of 16 kHz mono floats (~58 MB). Past that, new audio is dropped
    /// from the transcript (the kept recording still has it) and `overflowed` is set.
    static let maxSamples = 16_000 * 60 * 15

    private let lock = NSLock()
    private var queue: [Item] = []
    private var queued = 0
    private var target: AudioSink?
    private(set) var overflowed = false

    var isAttached: Bool { lock.lock(); defer { lock.unlock() }; return target != nil }

    /// Seconds of audio waiting for the model.
    var waitingSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(queued) / 16_000 }

    // TEMPORARY (0.5.3): samples handed straight to the session, for MeetingHealth.
    private var passed = 0
    func takePassedSamples() -> Int { lock.lock(); defer { lock.unlock() }; let n = passed; passed = 0; return n }

    func submit(_ s: [Float]) {
        lock.lock()
        if let t = target { passed += s.count; lock.unlock(); t.submit(s); return }
        if queued + s.count <= Self.maxSamples {
            queue.append(.samples(s)); queued += s.count
        } else {
            overflowed = true
        }
        lock.unlock()
    }

    func notePause(_ span: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if target == nil { queue.append(.pause(span)) }
    }

    /// Takes what is queued; if nothing is, attaches `sink` atomically so no sample
    /// can slip between the last replayed one and the first live one.
    func drainOrAttach(_ sink: AudioSink) -> [Item] {
        lock.lock(); defer { lock.unlock() }
        if queue.isEmpty { target = sink; return [] }
        let items = queue
        queue.removeAll(); queued = 0
        return items
    }

    /// Back to queueing (a new meeting before the model is ready, or after a stop).
    func reset(attachedTo sink: AudioSink?) {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll(); queued = 0; overflowed = false
        target = sink
    }
}
