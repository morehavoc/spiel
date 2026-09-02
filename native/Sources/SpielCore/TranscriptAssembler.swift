import Foundation

/// Reassembles concurrently-transcribed segments into speech order.
///
/// Fixes the out-of-order bug in the Electron app: `appendTranscript()` was called
/// from an async per-segment handler, so text landed in completion order. Here each
/// segment is stamped with its index when the audio is *captured*, and the assembler
/// only releases a prefix once it is contiguous from `nextToEmit`.
public actor TranscriptAssembler {
    private var pending: [Int: String] = [:]
    private var nextToEmit = 0
    private var emitted: [String] = []

    public init() {}

    /// Returns any newly contiguous text, in order. Empty if this segment arrived
    /// early and is still waiting on a gap ahead of it.
    @discardableResult
    public func accept(_ segment: TranscriptSegment) -> String {
        pending[segment.index] = segment.text
        var released = ""
        while let next = pending.removeValue(forKey: nextToEmit) {
            let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if !released.isEmpty { released += " " }
                released += trimmed
                emitted.append(trimmed)
            }
            nextToEmit += 1
        }
        return released
    }

    /// Full transcript so far, in speech order.
    public func text() -> String {
        emitted.joined(separator: " ")
    }

    /// Release anything still held back by a gap. Called when recording stops so a
    /// dropped or failed segment cannot swallow everything spoken after it.
    public func flush() -> String {
        var released = ""
        for key in pending.keys.sorted() {
            let trimmed = (pending[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if !released.isEmpty { released += " " }
                released += trimmed
                emitted.append(trimmed)
            }
        }
        pending.removeAll()
        return released
    }

    public func reset() {
        pending.removeAll()
        emitted.removeAll()
        nextToEmit = 0
    }
}
