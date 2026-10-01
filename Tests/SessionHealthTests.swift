import Foundation

@main struct SessionHealthTests {
    static func main() {
        var health = SessionHealth(now: 0), snapshot = AudioHealthSnapshot()
        // A silent conversation still generates callbacks. It must stay active.
        for i in 1...120 {
            snapshot.capture += 50; snapshot.render += 25
            precondition(health.failure(snapshot, engineRunning: true, now: Double(i) / 2) == nil)
        }
        // One isolated late buffer is tolerated; repeated starvation fails closed.
        snapshot.underflows += 1; snapshot.capture += 50; snapshot.render += 25
        precondition(health.failure(snapshot, engineRunning: true, now: 60.5) == nil)
        snapshot.underflows += 7; snapshot.capture += 50; snapshot.render += 25
        precondition(health.failure(snapshot, engineRunning: true, now: 61) != nil)
        var stalled = SessionHealth(now: 0)
        var onlyPlayback = AudioHealthSnapshot(); onlyPlayback.render = 100
        precondition(stalled.failure(onlyPlayback, engineRunning: true, now: 2) != nil)
        var onlyCapture = AudioHealthSnapshot(); onlyCapture.capture = 100
        stalled = SessionHealth(now: 0)
        precondition(stalled.failure(onlyCapture, engineRunning: true, now: 2) != nil)
        stalled = SessionHealth(now: 0)
        precondition(stalled.failure(AudioHealthSnapshot(), engineRunning: false, now: 0.1) != nil)
        for invalid in [true, false] {
            stalled = SessionHealth(now: 0)
            var fault = AudioHealthSnapshot(); fault.capture = 1; fault.render = 1
            if invalid { fault.invalidSamples = 1 } else { fault.formatErrors = 1 }
            precondition(stalled.failure(fault, engineRunning: true, now: 0.1) != nil)
        }
        stalled = SessionHealth(now: 0)
        snapshot = AudioHealthSnapshot(); snapshot.capture = 1; snapshot.render = 1
        precondition(stalled.failure(snapshot, engineRunning: true, now: 3) == nil)
        snapshot.capture += 1; snapshot.render += 1; snapshot.resets = 2
        precondition(stalled.failure(snapshot, engineRunning: true, now: 3.5) != nil)
        print("PASS callback supervision: silence preserved; starvation, stalled capture/playback, engine stop, invalid PCM/DSP, repeated backlog resets stop safely (policy test, not HAL recovery proof)")
    }
}
