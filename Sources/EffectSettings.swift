import Foundation
import AVFAudio
import AudioToolbox

struct EffectSettings: Codable, Equatable {
    var pitchEnabled = false
    var pitch = 0.0
    var preserveVocalShape = true
    var formantEnabled = false
    var formant = 0.0
    var eqEnabled = false
    var low = 0.0, mid = 0.0, high = 0.0
    var compressorEnabled = false
    var threshold = -18.0, ratio = 3.0, attack = 10.0, release = 100.0
    var volume = 1.0
    var parameters: DVCParameters {
        var p = dvc_default_parameters()
        p.pitch_semitones = Float(pitch); p.pitch_enabled = pitchEnabled
        p.preserve_vocal_shape = preserveVocalShape
        p.formant_semitones = Float(formant); p.formant_enabled = formantEnabled
        p.low_db = Float(low); p.mid_db = Float(mid); p.high_db = Float(high)
        p.threshold_db = Float(threshold); p.ratio = Float(ratio)
        p.attack_ms = Float(attack); p.release_ms = Float(release); p.volume = Float(volume)
        p.eq_enabled = eqEnabled; p.compressor_enabled = compressorEnabled
        return p
    }
    init() {}
    static var cuteSoft: EffectSettings {
        var settings = EffectSettings()
        settings.pitchEnabled = true; settings.pitch = 2.5
        settings.preserveVocalShape = true
        settings.formantEnabled = true; settings.formant = 1.0
        return settings
    }
    func matchesSound(_ other: EffectSettings) -> Bool {
        guard pitchEnabled == other.pitchEnabled, preserveVocalShape == other.preserveVocalShape,
              formantEnabled == other.formantEnabled, eqEnabled == other.eqEnabled,
              compressorEnabled == other.compressorEnabled else { return false }
        // SwiftUI stepped sliders can round-trip 1.700000000000001 to 1.7.
        // Such arithmetic noise must not mark a freshly loaded preset modified.
        let lhs = [pitch,formant,low,mid,high,threshold,ratio,attack,release,volume]
        let rhs = [other.pitch,other.formant,other.low,other.mid,other.high,other.threshold,other.ratio,other.attack,other.release,other.volume]
        return zip(lhs,rhs).allSatisfy { abs($0-$1) < 1e-8 }
    }
    private enum CodingKeys: String, CodingKey {
        case pitchEnabled, pitch, preserveVocalShape, formantEnabled, formant, eqEnabled, low, mid, high
        case compressorEnabled, threshold, ratio, attack, release, volume
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pitchEnabled = try c.decodeIfPresent(Bool.self, forKey: .pitchEnabled) ?? false
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
        // Keep old saved sounds unchanged until this new option is enabled.
        preserveVocalShape = try c.decodeIfPresent(Bool.self, forKey: .preserveVocalShape) ?? false
        formantEnabled = try c.decodeIfPresent(Bool.self, forKey: .formantEnabled) ?? false
        formant = try c.decodeIfPresent(Double.self, forKey: .formant) ?? 0
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? false
        low = try c.decodeIfPresent(Double.self, forKey: .low) ?? 0
        mid = try c.decodeIfPresent(Double.self, forKey: .mid) ?? 0
        high = try c.decodeIfPresent(Double.self, forKey: .high) ?? 0
        compressorEnabled = try c.decodeIfPresent(Bool.self, forKey: .compressorEnabled) ?? false
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? -18
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 3
        attack = try c.decodeIfPresent(Double.self, forKey: .attack) ?? 10
        release = try c.decodeIfPresent(Double.self, forKey: .release) ?? 100
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
    }
    mutating func sanitize() {
        func clamp(_ x: Double, _ a: Double, _ b: Double, _ fallback: Double) -> Double { x.isFinite ? min(b,max(a,x)) : fallback }
        pitch = clamp(pitch,-12,12,0); formant = clamp(formant,-8,8,0)
        low = clamp(low,-12,12,0); mid = clamp(mid,-12,12,0); high = clamp(high,-12,12,0)
        threshold = clamp(threshold,-48,0,-18); ratio = clamp(ratio,1,8,3)
        attack = clamp(attack,1,100,10); release = clamp(release,20,1000,100); volume = clamp(volume,0,1,1)
    }
}

enum EffectsFactory {
    static func make() throws -> AVAudioUnit {
        let semaphore = DispatchSemaphore(value: 0)
        var result: AVAudioUnit?, failure: Error?
        AVAudioUnit.instantiate(with: DVCRegisterEffectsAudioUnit(), options: [.loadInProcess]) { unit, error in
            result = unit; failure = error; semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw AudioFailure(stage: "Create in-process effects", status: nil, advice: "Audio Unit initialization timed out. Capture was not started.")
        }
        if let failure { throw failure }
        guard let result, result.auAudioUnit is DVCEffectsAudioUnit else {
            throw AudioFailure(stage: "Create in-process effects", status: nil, advice: "The private Audio Unit could not be initialized. Capture was not started.")
        }
        return result
    }
}
