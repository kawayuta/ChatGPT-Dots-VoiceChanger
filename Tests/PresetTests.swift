import Foundation

@main struct PresetTests {
    static func main() throws {
        let folder=URL(fileURLWithPath:"TestResults/preset-test-"+UUID().uuidString,isDirectory:true)
        let url=folder.appendingPathComponent("presets.json")
        var settings=EffectSettings();settings.pitchEnabled=true;settings.pitch=1.5;settings.formantEnabled=true;settings.formant=2;settings.eqEnabled=true;settings.low = -3
        let store=try PresetStore(url:url),saved=try store.save(name:"Warm sound",settings:settings)
        let loaded=try PresetStore(url:url)
        precondition(loaded.presets.count==1 && loaded.presets[0]==saved)
        try loaded.rename(id:saved.id,name:"やさしい声")
        let renamed=try PresetStore(url:url).presets[0]
        precondition(renamed.id==saved.id && renamed.settings==saved.settings && renamed.name=="やさしい声")
        settings.pitch = -3;try loaded.update(id:saved.id,settings:settings)
        let updated = try PresetStore(url:url); precondition(updated.presets[0].settings.pitch == -3)
        let original=try Data(contentsOf:url)
        for name in ["", "  ",String(repeating:"a",count:65),"line\nbreak"] {
            do { _=try loaded.save(name:name,settings:settings);fatalError("Invalid name was accepted") } catch is PresetError { }
        }
        do { _=try loaded.save(name:"やさしい声",settings:settings);fatalError("Duplicate name was accepted") } catch is PresetError { }
        let unchanged = try Data(contentsOf:url); precondition(unchanged == original)
        let permissions=(try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as! NSNumber).intValue
        precondition(permissions & 0o777 == 0o600)
        let json=String(decoding:original,as:UTF8.self)
        for forbidden in ["outputUID","targetPath","callConfirmed","token","audioSamples"] { precondition(!json.contains(forbidden)) }
        let defaultPreset = try loaded.save(name: "Default", settings: settings)
        precondition(loaded.initialPreset(preferredID: nil)?.id == defaultPreset.id)
        precondition(loaded.initialPreset(preferredID: saved.id)?.id == saved.id)
        try loaded.rename(id: defaultPreset.id, name: "Daily voice")
        precondition(loaded.initialPreset(preferredID: defaultPreset.id)?.name == "Daily voice")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        legacy.removeValue(forKey: "preserveVocalShape")
        let decoded = try JSONDecoder().decode(EffectSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        var expected = settings; expected.preserveVocalShape = false
        precondition(decoded == expected) // Existing user presets keep their previous sound.
        var sliderRoundtrip = settings; sliderRoundtrip.pitch += 1e-13
        precondition(sliderRoundtrip.matchesSound(settings))
        sliderRoundtrip.pitch += 0.1
        precondition(!sliderRoundtrip.matchesSound(settings))
        sliderRoundtrip = settings; sliderRoundtrip.preserveVocalShape.toggle()
        precondition(!sliderRoundtrip.matchesSound(settings))
        var compensated = EffectSettings(); compensated.pitchEnabled = true; compensated.pitch = 3
        precondition(compensated.parameters.pitch_semitones == 3 && compensated.parameters.preserve_vocal_shape && !compensated.parameters.formant_enabled)
        compensated.formantEnabled = true; compensated.formant = 2
        precondition(compensated.parameters.formant_semitones == 2 && compensated.parameters.formant_enabled)
        compensated.pitch = 1.5
        precondition(compensated.parameters.pitch_semitones == 1.5 && compensated.parameters.formant_semitones == 2)
        let invalid=Data("{\"version\":999,\"presets\":[]}".utf8);try invalid.write(to:url)
        do {_=try PresetStore(url:url);fatalError("Unsupported version was accepted")}catch is PresetError {}
        let preserved = try Data(contentsOf:url); precondition(preserved == invalid)
        try FileManager.default.removeItem(at:folder) // Only this test's UUID directory.
        print("PRESET_TESTS_PASS roundtrip=true rename_preserves_ID_and_settings=true startup_default_and_renamed_ID=true legacy_sound_preserved=true independent_formant_compensation=true update=true invalid_names_rejected=true unsupported_file_preserved=true permissions=0600 source_and_device_not_saved=true")
    }
}
