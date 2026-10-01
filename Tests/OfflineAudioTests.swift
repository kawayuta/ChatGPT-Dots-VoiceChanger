import Foundation
import AVFAudio
import Dispatch

struct OfflineFailure: Error, CustomStringConvertible { let description: String }
struct ToneResult: Codable {
    let rate: Double, channels: Int, semitones: Double
    let expectedHz: Double, measuredHz: Double, frequencyError: Double
    let activeSeconds: Double, durationError: Double, measuredOfflineOnsetDelayMs: Double
    let renderWallSeconds: Double, peak: Float
}
@main struct OfflineAudioTests {
    static func main() {
        DispatchQueue.global(qos: .userInitiated).async {
            do { try run(); exit(0) }
            catch { fputs("OFFLINE_AUDIO_TEST_FAILED: \(error)\n", stderr); exit(1) }
        }
        dispatchMain()
    }
    static func run() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "TestResults", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var results: [ToneResult] = []
        for rate in [24000.0,44100.0,48000.0] {
            for channels in [1,2] {
                for semitones in [0.0,-3.0,3.0,-12.0,12.0] {
                    let result = try render(rate: rate, channels: channels, semitones: semitones, folder: folder)
                    results.append(result)
                    print(String(format: "PITCH rate=%.0f channels=%d shift=%+.1f Hz=%.4f expected=%.4f frequency_error=%.5f duration=%.3f duration_error=%.5f offline_delay_ms=%.1f render_wall_seconds=%.3f PASS",rate,channels,semitones,result.measuredHz,result.expectedHz,result.frequencyError,result.activeSeconds,result.durationError,result.measuredOfflineOnsetDelayMs,result.renderWallSeconds))
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(results).write(to: folder.appendingPathComponent("offline-pitch-results.json"))
        print("OFFLINE_PITCH_AND_DURATION_TESTS_PASS (\(results.count) cases; core=signalsmith_80ms; software-only timing, NOT measured device latency)")
        for rate in [24000.0,44100.0,48000.0] {
            for shift in [-3.0,3.0] {
                let dry = try vowel(rate: rate, shift: shift, preserve: false, folder: folder)
                let compensated = try vowel(rate: rate, shift: shift, preserve: true, folder: folder)
                guard compensated < dry else { throw OfflineFailure(description: "Envelope compensation did not improve synthetic vowel resonances") }
                print(String(format: "VOCAL_SHAPE rate=%.0f pitch=%+.1f average_resonance_log_error_before=%.4f after=%.4f PASS (synthetic vowel; not a perceptual speech-quality score)", rate, shift, dry, compensated))
            }
        }
    }
    static func amplitude(_ samples: [Float], from: Int, count: Int, rate: Double, hz: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * hz / rate)
        var a = 0.0, b = 0.0
        for i in from..<from+count { let next = Double(samples[i]) + coefficient * a - b; b = a; a = next }
        return 2 * sqrt(max(0, a*a + b*b - coefficient*a*b)) / Double(count)
    }
    static func resonance(_ samples: [Float], rate: Double, f0: Double, center: Double) -> Double {
        let from = Int(rate * 3), count = Int(rate)
        var best = 0, peak = -1.0
        for h in Int(ceil(center * 0.75 / f0))...Int(floor(center * 1.3 / f0)) {
            let value = amplitude(samples, from: from, count: count, rate: rate, hz: f0 * Double(h))
            if value > peak { best = h; peak = value }
        }
        let left = log(max(1e-12, amplitude(samples, from: from, count: count, rate: rate, hz: f0 * Double(best-1))))
        let middle = log(max(1e-12, peak))
        let right = log(max(1e-12, amplitude(samples, from: from, count: count, rate: rate, hz: f0 * Double(best+1))))
        let offset = min(0.5,max(-0.5,0.5 * (left-right)/(left-2*middle+right)))
        return f0 * (Double(best) + offset)
    }
    static func vowel(rate: Double, shift: Double, preserve: Bool, folder: URL) throws -> Double {
        let count = Int(rate * 5), format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        var input = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var value = 0.0
            for h in 1...60 where Double(h)*120 < rate/2 {
                let hz = Double(h)*120
                let shape = 0.02 + 4*exp(-0.5*pow((hz-600)/130,2)) + 3*exp(-0.5*pow((hz-1800)/210,2)) + 2*exp(-0.5*pow((hz-3000)/250,2))
                value += 0.004*shape/sqrt(Double(h))*sin(2*Double.pi*hz*Double(i)/rate)
            }
            input[i] = Float(value)
        }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), effects = try EffectsFactory.make()
        var settings = EffectSettings(); settings.pitchEnabled = true; settings.pitch = shift; settings.preserveVocalShape = preserve
        (effects.auAudioUnit as! DVCEffectsAudioUnit).apply(settings.parameters)
        engine.attach(player); engine.attach(effects)
        engine.connect(player, to: effects, format: format); engine.connect(effects, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; buffer.frameLength = AVAudioFrameCount(count)
        input.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
        player.scheduleBuffer(buffer); engine.prepare(); try engine.start(); player.play()
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var samples: [Float] = []; samples.reserveCapacity(count); var retries = 0
        while samples.count < count {
            let n = AVAudioFrameCount(min(1024, count-samples.count)), status = try engine.renderOffline(n, to: block)
            if status == .cannotDoInCurrentContext { retries += 1; if retries > 100 { throw OfflineFailure(description: "Vowel render stalled") }; continue }
            guard status == .success || status == .insufficientDataFromInputNode, block.frameLength == n else { throw OfflineFailure(description: "Vowel render error") }
            retries = 0; samples.append(contentsOf: UnsafeBufferPointer(start: block.floatChannelData![0], count: Int(n)))
        }
        engine.stop(); player.stop()
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 0.981 }) else { throw OfflineFailure(description: "Invalid vowel output") }
        let expectedF0 = 120 * pow(2, shift/12)
        var bestLag = 0, bestCorrelation = -Double.infinity
        let from = Int(rate*3), length = 10000
        for lag in Int(rate/expectedF0*0.97)...Int(rate/expectedF0*1.03) {
            var dot = 0.0, a = 0.0, b = 0.0
            for i in from..<from+length { let x = Double(samples[i]), y = Double(samples[i+lag]); dot += x*y; a += x*x; b += y*y }
            let correlation = dot/sqrt(a*b)
            if correlation > bestCorrelation { bestCorrelation = correlation; bestLag = lag }
        }
        guard abs(rate/Double(bestLag)/expectedF0-1) < 0.01 else { throw OfflineFailure(description: "Vocal-shape compensation altered fundamental pitch") }
        var error = 0.0
        for center in [600.0,1800.0,3000.0] {
            let original = resonance(input, rate: rate, f0: 120, center: center)
            let actual = resonance(samples, rate: rate, f0: expectedF0, center: center)
            error += abs(log(actual/original))/3
        }
        if rate == 48000 && shift == 3 {
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent("synthetic-vowel-pitch3-shape-\(preserve ? "on" : "off").wav"), settings: format.settings)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }; try file.write(from: buffer)
            if !preserve {
                let original = try AVAudioFile(forWriting: folder.appendingPathComponent("synthetic-vowel-original.wav"), settings: format.settings)
                input.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }; try original.write(from: buffer)
            }
        }
        return error
    }
    static func render(rate: Double, channels: Int, semitones: Double, folder: URL) throws -> ToneResult {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let effects = try EffectsFactory.make()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
        engine.attach(player); engine.attach(effects)
        var settings = EffectSettings(); settings.pitchEnabled = true; settings.pitch = semitones
        (effects.auAudioUnit as! DVCEffectsAudioUnit).apply(settings.parameters)
        engine.connect(player, to: effects, format: format)
        engine.connect(effects, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let count = Int(rate * 12), start = Int(rate * 0.5), end = Int(rate * 10.5)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        input.frameLength = AVAudioFrameCount(count)
        for c in 0..<channels {
            for i in 0..<count { input.floatChannelData![c][i] = i >= start && i < end ? 0.1 * sin(Float(2 * Double.pi * 440 * Double(i-start) / rate)) : 0 }
        }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var samples: [Float] = []; samples.reserveCapacity(count)
        player.scheduleBuffer(input, at: nil)
        engine.prepare(); try engine.start(); player.play()
        let began = ProcessInfo.processInfo.systemUptime
        var retries = 0
        while samples.count < count {
            let frames = AVAudioFrameCount(min(1024,count-samples.count))
            switch try engine.renderOffline(frames, to: output) {
            case .success, .insufficientDataFromInputNode:
                guard output.frameLength == frames else { throw OfflineFailure(description: "Unexpected offline output frame count") }
                samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(frames))); retries = 0
            case .cannotDoInCurrentContext:
                retries += 1; if retries > 100 { throw OfflineFailure(description: "Offline rendering did not advance") }
            case .error: throw OfflineFailure(description: "Offline engine returned an error")
            @unknown default: throw OfflineFailure(description: "Unknown offline render status")
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        engine.stop(); player.stop()
        let bin = Int(rate * 0.01)
        var active: [Int] = []
        for base in stride(from: 0, to: count-bin, by: bin) {
            var power = 0.0
            for i in base..<base+bin { power += Double(samples[i])*Double(samples[i]) }
            if sqrt(power/Double(bin)) > 0.02 { active.append(base) }
        }
        guard let first = active.first, let last = active.last else { throw OfflineFailure(description: "No synthetic tone was rendered") }
        let seconds = Double(last+bin-first)/rate
        let lo = first+Int(rate), hi = min(count-1,first+Int(rate*8))
        var crossings: [Double] = []
        for i in lo+1..<hi where samples[i-1] <= 0 && samples[i] > 0 {
            let a=Double(samples[i-1]),b=Double(samples[i]); crossings.append(Double(i-1)-a/(b-a))
        }
        guard crossings.count > 10 else { throw OfflineFailure(description: "Insufficient tone zero crossings") }
        let frequency = Double(crossings.count-1)*rate/(crossings.last!-crossings.first!)
        let expected = 440*pow(2,semitones/12), frequencyError=abs(frequency/expected-1), durationError=abs(seconds/10-1)
        guard frequencyError <= 0.01, durationError <= 0.01 else {
            throw OfflineFailure(description: "Pitch/duration acceptance failed: \(rate) Hz / \(channels) ch / \(semitones) st; measured \(frequency) Hz, \(seconds) seconds")
        }
        let peak = samples.reduce(Float(0)) { max($0,abs($1)) }
        guard samples.allSatisfy({ $0.isFinite }), peak <= 0.981 else { throw OfflineFailure(description: "Invalid or clipped synthetic output") }
        if channels == 1 && (semitones == 0 || semitones == 12) {
            let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            rendered.frameLength=AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { rendered.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
            let file=try AVAudioFile(forWriting: folder.appendingPathComponent("synthetic-440hz-\(Int(rate))-pitch\(Int(semitones)).wav"), settings: format.settings)
            try file.write(from: rendered) // Synthetic fixtures only. This tool never captures real audio.
        }
        return ToneResult(rate: rate,channels: channels,semitones: semitones,expectedHz: expected,measuredHz: frequency,frequencyError: frequencyError,activeSeconds: seconds,durationError: durationError,measuredOfflineOnsetDelayMs: (Double(first)/rate-0.5)*1000,renderWallSeconds: elapsed,peak: peak)
    }
}
