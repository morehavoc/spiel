import Foundation

/// Turns the loudness of each mic buffer into the 0…1 height of the level bars in
/// the dictation panel and the Listen sidebar.
///
/// The bars used to read a fixed window, −48 dBFS empty to −18 dBFS full, tuned on
/// 2026-09-02 against a MacBook Pro Microphone at conversational distance. Input
/// quieter than that window leaves every bar at its minimum while the transcript
/// still fills in: a multichannel mic that Spiel mixes to mono itself since 2.5.1
/// (the MacBook Pro's 3-capsule array), a low input volume, or a speaker across a
/// room during Listen. Christopher, 2026-10-22: "the thing that indicates it is
/// hearing you is very small or non existent".
///
/// So the window also follows the input. Its bottom is the quiet end of the last
/// few seconds and its top the loud end, both read as percentiles so one dropout or
/// one cough cannot move them, and it is never narrower than `minSpan`, so steady
/// room noise alone stays near empty. The fixed window stays as a lower bound: a mic
/// that already moved the bars moves them at least as much as before.
public struct LevelMeter: Sendable {
    /// Buffers quieter than this are digital silence (a muted or disconnected
    /// input). They read as empty and stay out of the window, so a muted stretch
    /// cannot drag the bottom down and make the room noise after it fill the bars.
    public static let silenceDB: Float = -80
    /// Buffers in the window. The mic delivers about 47 a second, so ~3 s.
    public static let windowSize = 150
    /// dB above the quiet end of the window before a bar rises.
    public static let floorMargin: Float = 3
    /// The window is never narrower than this many dB. 15 keeps a click 5 dB over
    /// the room near the bottom (selftest 2.7.4). 12 was tried: on a talk recorded
    /// by a camera across the room and turned down 25 dB it lifted the share of
    /// buffers at half height from 11 % to 19 %, and the same click to 27 %.
    public static let minSpan: Float = 15
    /// The fixed window the bars used before 2.7.4, kept as a lower bound.
    public static let fixedLow: Float = -48
    public static let fixedHigh: Float = -18

    private var recent: [Float] = []
    private var next = 0

    public init() {}

    /// dBFS of an RMS amplitude (1.0 = full scale).
    public static func dBFS(rms: Float) -> Float { 20 * log10(max(rms, 1e-7)) }

    /// The pre-2.7.4 mapping on its own.
    public static func fixedLevel(dB: Float) -> Float {
        min(max((dB - fixedLow) / (fixedHigh - fixedLow), 0), 1)
    }

    /// The bar height for one buffer at `dB`, which also joins the window.
    public mutating func level(dB: Float) -> Float {
        guard dB.isFinite, dB >= Self.silenceDB else { return 0 }
        if recent.count < Self.windowSize {
            recent.append(dB)
        } else {
            recent[next] = dB
            next = (next + 1) % Self.windowSize
        }
        let sorted = recent.sorted()
        let quiet = sorted[Int(Float(sorted.count - 1) * 0.10)]
        let loud = sorted[Int(Float(sorted.count - 1) * 0.95)]
        let low = quiet + Self.floorMargin
        let high = max(loud, low + Self.minSpan)
        let adaptive = min(max((dB - low) / (high - low), 0), 1)
        return max(adaptive, Self.fixedLevel(dB: dB))
    }
}
