import Foundation

// Non-realtime supervision. Silence is valid: only callback progress and data
// loss/error counters enter the policy, never voice activity or sample level.
struct AudioHealthSnapshot {
    var capture: UInt64 = 0, render: UInt64 = 0
    var underflows: UInt64 = 0, overflows: UInt64 = 0, resets: UInt64 = 0
    var formatErrors: UInt64 = 0, invalidSamples: UInt64 = 0
}
struct SessionHealth {
    private var previous = AudioHealthSnapshot()
    private var began: TimeInterval, captureProgress: TimeInterval, renderProgress: TimeInterval
    private var window: TimeInterval
    private var losses: UInt64 = 0, discontinuities: UInt64 = 0
    init(now: TimeInterval) { began = now; captureProgress = now; renderProgress = now; window = now }
    mutating func failure(_ snapshot: AudioHealthSnapshot, engineRunning: Bool, now: TimeInterval) -> String? {
        if snapshot.capture != previous.capture { captureProgress = now }
        if snapshot.render != previous.render { renderProgress = now }
        defer { previous = snapshot }
        if !engineRunning { return "The playback engine stopped." }
        if now - captureProgress >= 2 { return "Capture callbacks stopped advancing." }
        if now - renderProgress >= 2 { return "Playback callbacks stopped advancing." }
        if snapshot.formatErrors > 0 { return "The callback PCM layout changed." }
        if snapshot.invalidSamples > 0 { return "The effects processor detected invalid samples." }
        if now - window >= 2 { window = now; losses = 0; discontinuities = 0 }
        if now - began >= 3 {
            losses += snapshot.underflows >= previous.underflows ? snapshot.underflows - previous.underflows : 0
            discontinuities += snapshot.overflows >= previous.overflows ? snapshot.overflows - previous.overflows : 0
            discontinuities += snapshot.resets >= previous.resets ? snapshot.resets - previous.resets : 0
            if losses >= 8 || discontinuities >= 2 { return "Repeated buffer starvation or discontinuities made playback unreliable." }
        }
        return nil
    }
}
