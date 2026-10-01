import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    @Published var state: SessionState = .stopped
    @Published var message = "Start a desktop voice call, verify the source, then start processing manually."
    @Published var inspection: Inspection?
    @Published var targetURL: URL?
    @Published var outputUID = ""
    @Published var settings = EffectSettings() { didSet { if !isPreview { applySettings() } } }
    @Published var callConfirmed = false
    @Published var refreshing = false
    @Published var statistics = "No capture session yet."
    @Published var reduction = 0.0
    @Published var outputPeak = 0.0
    @Published var legacyPrototypeRunning = false
    @Published var presets: [SoundPreset] = []
    @Published var selectedPresetID: UUID?
    @Published var presetError = ""
    @Published var startupPresetID: UUID?
    @Published var automaticEnabled = false
    @Published var automaticMessage = "Automatic mode is off."
    private var automaticTimer: Timer?
    private var automaticInspecting = false
    private var automaticCandidate: Inspection?
    private var automaticActiveCount = 0, automaticInactiveCount = 0
    private var presetStore: PresetStore?
    let session = AudioSession()
    let isPreview: Bool
    init(preview: Bool = false) {
        isPreview = preview
        if preview { targetURL = URL(fileURLWithPath: "/Applications/ChatGPT.app"); return }
        if let saved = UserDefaults.standard.string(forKey: "targetPath"), FileManager.default.fileExists(atPath: saved) {
            targetURL = URL(fileURLWithPath: saved, isDirectory: true)
        } else { targetURL = Inspection.recommendedAppURL() }
        outputUID = UserDefaults.standard.string(forKey: "outputUID") ?? ""
        if let data = UserDefaults.standard.data(forKey: "effectSettings"), let saved = try? JSONDecoder().decode(EffectSettings.self, from: data) {
            settings = saved; settings.sanitize()
        }
        session.onUpdate = { [weak self] update in
            guard let self else { return }
            self.state = update.state; self.message = update.message
            if let s = update.stats {
                self.statistics = "Capture callbacks  \(s.capture_callbacks)\nPlayback callbacks  \(s.render_callbacks)\nUnderflows  \(s.underflows)   ·   Overflows  \(s.overflows)\nBacklog resets  \(s.backlog_resets)   ·   Queued frames  \(s.queued_frames)\nClock correction  \(String(format: "%.6f", s.drift_ratio))   ·   Input peak  \(String(format: "%.3f", s.peak))"
                if let format = update.format { self.statistics = format + "\n" + self.statistics }
            }
            if let d = update.dspStats {
                self.reduction = Double(d.reduction_db); self.outputPeak = Double(d.output_peak)
                if update.stats != nil { self.statistics += "\nDSP frames  \(d.frames)   ·   Peak protection frames  \(d.protection_frames)\nInvalid samples  \(d.nonfinite_samples)" }
            }
            if update.state == .stopped || update.state == .error { self.callConfirmed = false; self.reduction = 0; self.outputPeak = 0 }
            if update.state == .error && self.automaticEnabled { self.setAutomatic(false); self.automaticMessage = "Automatic mode paused after an audio error. Verify the source/device before enabling it again." }
        }
        do {
            let store = try PresetStore(url: PresetStore.applicationURL()); presetStore = store; presets = store.presets
            let preferred = UserDefaults.standard.string(forKey: "startupPresetID").flatMap(UUID.init(uuidString:))
            if let preset = store.initialPreset(preferredID: preferred) {
                startupPresetID = preset.id; selectedPresetID = preset.id; settings = preset.settings
                UserDefaults.standard.set(preset.id.uuidString, forKey: "startupPresetID")
            }
        }
        catch { presetError = "Could not load presets: " + error.localizedDescription }
        automaticEnabled = UserDefaults.standard.bool(forKey: "automaticPlayback")
        automaticMessage = automaticEnabled ? "Waiting for verified ChatGPT playback. This is not call detection." : "Automatic mode is off."
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.pollAutomatic() }
        RunLoop.main.add(timer, forMode: .common); automaticTimer = timer
        refresh()
    }
    deinit { automaticTimer?.invalidate() }
    var busy: Bool { state == .preparing || state == .checking || state == .running || state == .recovering }
    var sourceEligible: Bool { !isPreview && !busy && !refreshing && !legacyPrototypeRunning && !(inspection?.targets.isEmpty ?? true) && inspection?.outputs.contains(where: { $0.uid == outputUID }) == true }
    var canStart: Bool { sourceEligible && callConfirmed }
    var startHint: String? {
        if busy || isPreview { return nil }
        if refreshing { return "Verifying source and devices…" }
        if legacyPrototypeRunning { return "Another capture app is playing audio. Stop or quit it, then refresh." }
        if inspection == nil { return "Choose and open the official desktop app, then refresh." }
        if inspection?.targets.isEmpty == true { return "No verified audio process. Start your call and refresh." }
        if automaticEnabled { return automaticMessage }
        if inspection?.outputs.contains(where: { $0.uid == outputUID }) != true { return "Choose an available output device." }
        if !callConfirmed { return "Confirm that your desktop voice call is running to enable Start." }
        return nil
    }
    func refresh() {
        guard !isPreview, !busy, !refreshing else { return }
        callConfirmed = false
        guard let targetURL else { inspection = nil; message = "Choose the official ChatGPT desktop app to begin."; return }
        refreshing = true
        session.inspect(appURL: targetURL) { [weak self] result in
            guard let self else { return }
            self.refreshing = false
            switch result {
            case .success(let i):
                self.state = .stopped
                self.inspection = i
                self.legacyPrototypeRunning = i.competingCaptureOutput
                // Initialize once. A disconnected explicit choice must not silently
                // redirect processed voice to speakers or a different device.
                if self.outputUID.isEmpty {
                    self.outputUID = i.outputs.first(where: { $0.objectID == i.defaultOutput })?.uid ?? i.outputs.first?.uid ?? ""
                }
                self.message = i.targets.isEmpty ? "No verified audio process is available. Start a desktop voice call and refresh." : "Signature, executable, and helper ancestry verified. Start processing when your call is running."
            case .failure(let error): self.state = .error; self.inspection = nil; self.message = error.localizedDescription
            }
        }
    }
    func chooseApplication() {
        guard !isPreview, !busy else { return }
        let panel = NSOpenPanel(); panel.title = "Choose the official ChatGPT desktop app"; panel.prompt = "Choose app"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url {
            targetURL = url; UserDefaults.standard.set(url.path, forKey: "targetPath"); refresh()
        }
    }
    func start(_ mode: SessionMode = .effects, automatic: Bool = false) {
        guard automatic ? automaticEnabled && sourceEligible : canStart, let inspection else { return }
        state = .preparing; UserDefaults.standard.set(outputUID, forKey: "outputUID")
        session.start(expected: inspection, outputUID: outputUID, settings: settings, mode: mode)
    }
    func stop() { setAutomatic(false, stopPlayback: false); session.stop() }
    func applySettings() {
        guard !isPreview else { return }
        var safe = settings; safe.sanitize()
        if settings != safe { settings = safe; return }
        session.setSettings(safe)
        if let data = try? JSONEncoder().encode(safe) { UserDefaults.standard.set(data, forKey: "effectSettings") }
    }
    var selectedPreset: SoundPreset? { presets.first { $0.id == selectedPresetID } }
    var startupPreset: SoundPreset? { presets.first { $0.id == startupPresetID } }
    func useAtLaunch(_ preset: SoundPreset) { startupPresetID = preset.id; UserDefaults.standard.set(preset.id.uuidString, forKey: "startupPresetID") }
    func loadPreset(_ preset: SoundPreset) { settings = preset.settings; selectedPresetID = preset.id }
    func savePreset(name: String) -> Bool {
        do {
            guard let store = presetStore else { throw PresetError(message: "Preset storage is unavailable. Existing files have not been overwritten.") }
            let p = try store.save(name: name, settings: settings); presets = store.presets; selectedPresetID = p.id; presetError = ""; return true
        } catch { presetError = error.localizedDescription; return false }
    }
    func renamePreset(id: UUID, name: String) -> Bool {
        do { guard let store = presetStore else { throw PresetError(message: "Preset storage is unavailable.") }; try store.rename(id: id, name: name); presets = store.presets; presetError = ""; return true }
        catch { presetError = error.localizedDescription; return false }
    }
    func updatePreset() {
        do { guard let store = presetStore, let id = selectedPresetID else { return }; try store.update(id: id, settings: settings); presets = store.presets; presetError = "" }
        catch { presetError = error.localizedDescription }
    }

    func setAutomatic(_ enabled: Bool, stopPlayback: Bool = true) {
        guard !isPreview else { return }
        automaticEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "automaticPlayback")
        automaticActiveCount = 0; automaticInactiveCount = 0; automaticCandidate = nil
        automaticMessage = enabled ? "Waiting for verified ChatGPT playback. Notifications may also trigger processing." : "Automatic mode is off."
        if stopPlayback && ((!enabled && busy) || (enabled && state == .checking)) { session.stop() }
    }
    private func pollAutomatic() {
        guard automaticEnabled, !isPreview, !refreshing, !automaticInspecting,
              state != .preparing, state != .recovering, let targetURL else { return }
        automaticInspecting = true
        session.inspect(appURL: targetURL) { [weak self] result in
            guard let self else { return }
            self.automaticInspecting = false
            guard self.automaticEnabled else { return }
            switch result {
            case .failure:
                self.automaticActiveCount = 0; self.automaticCandidate = nil
                self.automaticMessage = "Waiting for the selected official app and a verifiable audio process."
            case .success(let current):
                guard !current.competingCaptureOutput,
                      current.outputs.contains(where: { $0.uid == self.outputUID }) else {
                    self.setAutomatic(false); self.automaticMessage = "Automatic mode paused. Choose an available output and stop any competing capture app."; return
                }
                let active = current.targets.contains { $0.runningOutput }
                if self.busy {
                    self.automaticInactiveCount = active ? 0 : self.automaticInactiveCount + 1
                    if self.automaticInactiveCount >= 2 { self.session.stop(); self.automaticMessage = "ChatGPT playback stopped. Waiting for the next verified output." }
                    return
                }
                self.inspection = current; self.legacyPrototypeRunning = false
                let stable = self.automaticCandidate.map { $0.root == current.root && $0.targets == current.targets } ?? false
                self.automaticActiveCount = active ? (stable ? self.automaticActiveCount + 1 : 1) : 0
                self.automaticCandidate = current
                if self.automaticActiveCount >= 2 {
                    self.automaticMessage = "Applying sound to verified ChatGPT playback. This is not call detection."
                    self.start(.effects, automatic: true)
                }
            }
        }
    }

}
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { Self.model?.session.stopSynchronously(); return .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { Self.model?.isPreview == true }
}
#if !UI_PREVIEW
@main struct DotsVoiceChangerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private static let isPreview = Bundle.main.object(forInfoDictionaryKey: "DVCUIShowcase") as? Bool == true
    @StateObject private var model: AppModel
    init() {
        let instance = AppModel(preview: Self.isPreview)
        _model = StateObject(wrappedValue: instance); AppDelegate.model = instance
    }
    var body: some Scene {
        WindowGroup("Dots Voice Changer", id: "voice-controls") {
            ContentView(model: model, preview: Self.isPreview)
                .frame(minWidth: 700, idealWidth: 760, maxWidth: 960, minHeight: 740)
        }.defaultSize(width: 760, height: 910)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Emergency stop — restore original audio") { model.stop() }.keyboardShortcut(".", modifiers: [.command])
            }
        }
        MenuBarExtra(isInserted: .constant(!Self.isPreview)) { VoiceMenu(model: model) } label: {
            Image(systemName: model.state == .running ? "waveform.circle.fill" : "waveform.circle")
                .accessibilityLabel("Dots Voice Changer — \(model.state.rawValue)")
        }
    }
}
#endif
struct VoiceMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Dots Voice Changer · \(model.state.rawValue)")
        if let preset = model.selectedPreset { Text("Sound: \(preset.name)") }
        Button("Open controls") { openWindow(id: "voice-controls"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Toggle("Auto apply on ChatGPT playback", isOn: Binding(get: { model.automaticEnabled }, set: { model.setAutomatic($0) }))
        if !model.automaticEnabled { Toggle("My desktop call is running", isOn: $model.callConfirmed).disabled(model.busy) }
        Button("Start processing") { model.start() }.disabled(!model.canStart)
        Button("Stop & restore original") { model.stop() }.disabled(!model.busy && !model.automaticEnabled)
        if !model.presets.isEmpty {
            Menu("Presets") { ForEach(model.presets) { preset in Button(preset.name) { model.loadPreset(preset) } } }
        }
        Divider()
        Button("Quit Dots Voice Changer") { NSApp.terminate(nil) }
    }
}
private let voiceAccent = Color(red: 0.13, green: 0.53, blue: 0.46)
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor).opacity(0.30), lineWidth: 1))
    }
}
struct EffectHeader: View {
    var title: String; var subtitle: String; var symbol: String
    @Binding var enabled: Bool
    var reset: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(enabled ? voiceAccent : .secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 4)
            Button(action: reset) { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).help("Reset \(title)")
            Toggle(title, isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Enable \(title)")
        }
    }
}
struct ParameterSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.1
    var unit: String
    var decimals = 1
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField(title, value: $value, format: .number.precision(.fractionLength(decimals)))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).font(.system(.body, design: .monospaced)).frame(width: 55)
                Text(unit).font(.caption).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .leading)
            }
            Slider(value: $value, in: range, step: step).tint(voiceAccent).accessibilityLabel(title)
        }
    }
}
struct ToneDial: View {
    var title: String; var subtitle: String
    @Binding var value: Double
    @State private var origin: Double?
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: max(0.001, (value + 12)/24 * 0.75)).stroke(voiceAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(135))
                Circle().fill(LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)], startPoint: .top, endPoint: .bottom)).padding(10)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.15)).padding(10))
                Capsule().fill(voiceAccent).frame(width: 3, height: 12).offset(y: -22).rotationEffect(.degrees(-135 + (value+12)/24*270))
            }.frame(width: 80, height: 80).contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    if origin == nil { origin = value }
                    let delta = Double(drag.startLocation.y-drag.location.y) / 6.0
                    value = min(12, max(-12, ((origin ?? 0) + delta).rounded()))
                }.onEnded { _ in origin = nil })
                .accessibilityLabel("\(title) EQ gain").accessibilityValue("\(Int(value)) decibels")
                .accessibilityAdjustableAction { direction in value = min(12,max(-12,value + (direction == .increment ? 1 : -1))) }
                .help("Drag up or down to adjust. Double-click the value to type a gain.")
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.center).frame(width: 48).font(.system(.body, design: .monospaced))
                Text("dB").font(.caption).foregroundStyle(.secondary)
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            Slider(value: $value, in: -12...12, step: 1).tint(voiceAccent).accessibilityLabel("\(title) EQ slider").frame(maxWidth: 150)
        }.frame(maxWidth: .infinity)
    }
}
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showDetails = false
    @State private var showLibrary = false
    @State private var editName = ""
    @State private var renameID: UUID?
    @State private var showNameEditor = false
    var preview = false
    private var statusColor: Color {
        switch model.state { case .checking, .running: return voiceAccent; case .error: return .red; case .preparing, .recovering: return .orange; case .stopped: return .secondary }
    }
    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    routing
                    presetBar
                    HStack(spacing: 8) {
                        Text("SIGNAL FLOW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Pitch → Formant → EQ → Compressor → Output").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset all") { model.settings = EffectSettings() }.buttonStyle(.borderless).font(.caption)
                    }.padding(.horizontal, 2)
                    HStack(alignment: .top, spacing: 16) { pitchCard; formantCard }
                    eqCard
                    compressorCard
                    outputCard
                    diagnostics
                    if preview { Text("UI preview · Synthetic device labels · Stopped state · No audio capture").font(.caption).foregroundStyle(.secondary) }
                }.padding(24)
            }
            Divider()
            controls.padding(.horizontal, 24).padding(.vertical, 15)
        }.background(Color(nsColor: .windowBackgroundColor)).tint(voiceAccent)
            .sheet(isPresented: $showLibrary) { presetLibrary }
            .sheet(isPresented: $showNameEditor) { nameEditor }
    }
    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "waveform").font(.system(size: 25, weight: .medium)).foregroundStyle(voiceAccent)
                .frame(width: 48, height: 48).background(voiceAccent.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("Dots Voice Changer").font(.system(size: 23, weight: .semibold))
                Text("Shape the voice you hear.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) { Circle().fill(statusColor).frame(width: 7, height: 7); Text(model.state.rawValue).font(.caption.weight(.semibold)) }
                .padding(.horizontal, 12).padding(.vertical, 8).background(statusColor.opacity(0.10)).clipShape(Capsule())
        }
    }

    private var presetBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark").foregroundStyle(voiceAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedPreset?.name ?? "Custom sound").font(.subheadline.weight(.medium))
                Text(model.selectedPreset.map { $0.settings.matchesSound(model.settings) ? "Saved preset" : "Modified · not saved yet" } ?? "Save your settings as a reusable preset").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Presets…") { showLibrary = true }.disabled(preview)
            if model.selectedPreset != nil { Button("Update") { model.updatePreset() }.disabled(preview || model.selectedPreset?.settings.matchesSound(model.settings) == true) }
            Button("Save as…") { renameID = nil; editName = ""; model.presetError = ""; showNameEditor = true }.disabled(preview)
        }.padding(.horizontal, 2)
    }
    private var presetLibrary: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Your presets").font(.title2.weight(.semibold)); Spacer(); Button("Done") { showLibrary = false } }
            Text("Presets save effects and volume. Source applications, device IDs, and call state are never included.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Starting points").font(.subheadline.weight(.medium))
                    Text("Try a sound, then save your own version.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cute · Soft") { model.settings = .cuteSoft; model.selectedPresetID = nil; showLibrary = false }
                Button("Neutral") { model.settings = EffectSettings(); model.selectedPresetID = nil; showLibrary = false }
            }
            if model.presets.isEmpty { Text("No saved presets yet. Adjust your sound, then choose Save as….").foregroundStyle(.secondary).padding(.vertical, 24) }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.presets) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text(preset.name).font(.headline); Text(String(format: "Pitch %+.1f st · Formant %+.1f st",preset.settings.pitch,preset.settings.formant)).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if model.startupPresetID == preset.id { Image(systemName: "star.fill").foregroundStyle(voiceAccent).help("Loaded at launch") }
                            else { Button("Use at launch") { model.useAtLaunch(preset) } }
                            Button("Rename…") { renameID = preset.id; editName = preset.name; model.presetError = ""; showLibrary = false; DispatchQueue.main.async { showNameEditor = true } }
                            Button("Load") { model.loadPreset(preset); showLibrary = false }.buttonStyle(.borderedProminent)
                        }.padding(13).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            if !model.presetError.isEmpty { Text(model.presetError).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 650, height: 450)
    }
    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(renameID == nil ? "Save sound preset" : "Rename preset").font(.title2.weight(.semibold))
            TextField("Preset name", text: $editName).textFieldStyle(.roundedBorder).onSubmit { commitPresetName() }
            Text("1–64 characters. Stored locally on this Mac.").font(.caption).foregroundStyle(.secondary)
            if !model.presetError.isEmpty { Text(model.presetError).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { showNameEditor = false }.keyboardShortcut(.cancelAction); Button(renameID == nil ? "Save" : "Rename") { commitPresetName() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 420)
    }
    private func commitPresetName() {
        let success = renameID.map { model.renamePreset(id: $0, name: editName) } ?? model.savePreset(name: editName)
        if success { showNameEditor = false }
    }
    private var routing: some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(model.targetURL?.deletingPathExtension().lastPathComponent ?? "Choose ChatGPT", systemImage: "bubble.left.and.bubble.right").font(.headline)
                    Text(model.inspection.map { "\($0.version) · \($0.targets.count) verified audio processes" } ?? (preview ? "Official desktop voice source" : "Official desktop app required")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose app…") { model.chooseApplication() }.disabled(model.busy)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(model.busy || model.refreshing).help("Refresh process and device identities")
            }
            Picker("Output", selection: $model.outputUID) {
                Text(preview ? "USB Headphones · 48,000 Hz (preview)" : "Choose output").tag("")
                if !model.outputUID.isEmpty && model.inspection?.outputs.contains(where: { $0.uid == model.outputUID }) != true {
                    Text("Selected output unavailable — reconnect or choose another").tag(model.outputUID)
                }
                ForEach(model.inspection?.outputs ?? []) { output in Text("\(output.name) · \(Int(output.sampleRate)) Hz").tag(output.uid) }
            }.disabled(model.busy)
            Toggle("Auto apply on ChatGPT playback", isOn: Binding(get: { model.automaticEnabled }, set: { model.setAutomatic($0) })).disabled(preview)
            if !model.automaticEnabled { Toggle("My desktop voice call is running", isOn: $model.callConfirmed).disabled(model.busy) }
            Text(model.automaticEnabled ? "Output activity triggers processing; this is not call detection. Notifications from the same verified processes may also be processed." : "Manual start. All sounds from the verified ChatGPT processes may be included, including notifications.").font(.caption).foregroundStyle(.secondary)
            if let preset = model.startupPreset { Text("Launch preset: \(preset.name)").font(.caption2).foregroundStyle(.secondary) }
            if model.legacyPrototypeRunning { Label("Another capture app is playing audio. Stop or quit it, then refresh.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        }
    }
    private var pitchCard: some View {
        Card {
            EffectHeader(title: "Pitch", subtitle: "Voice height · speed unchanged", symbol: "waveform.path", enabled: $model.settings.pitchEnabled) { model.settings.pitch = 0; model.settings.pitchEnabled = false }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TextField("Pitch", value: $model.settings.pitch, format: .number.sign(strategy: .always()).precision(.fractionLength(1))).textFieldStyle(.plain).font(.system(size: 30, weight: .medium, design: .rounded)).frame(width: 112).accessibilityLabel("Pitch semitones value")
                Text("semitones").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $model.settings.pitch, in: -12...12, step: 0.1).accessibilityLabel("Pitch semitones")
            HStack { Text("−12 · Lower"); Spacer(); Text("0"); Spacer(); Text("Higher · +12") }.font(.caption2).foregroundStyle(.secondary)
            Text("Speed stays unchanged. Large shifts can reduce voice quality.").font(.caption).foregroundStyle(.secondary)
            Toggle("Preserve vocal shape", isOn: $model.settings.preserveVocalShape).font(.caption)
            Text("Preserve the original vocal resonances while changing pitch.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var formantCard: some View {
        Card {
            EffectHeader(title: "Formant", subtitle: "Voice colour · independent of pitch", symbol: "waveform.path.ecg", enabled: $model.settings.formantEnabled) { model.settings.formant = 0; model.settings.formantEnabled = false }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TextField("Formant", value: $model.settings.formant, format: .number.sign(strategy: .always()).precision(.fractionLength(1))).textFieldStyle(.plain).font(.system(size: 30, weight: .medium, design: .rounded)).frame(width: 112).accessibilityLabel("Formant semitones value")
                Text("semitones").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $model.settings.formant, in: -8...8, step: 0.1).accessibilityLabel("Formant envelope semitones")
            HStack { Text("−8 · Darker"); Spacer(); Text("0"); Spacer(); Text("Brighter · +8") }.font(.caption2).foregroundStyle(.secondary)
            Text("Spectral-envelope shift in the pitch engine. An approximation; not voice cloning.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var eqCard: some View {
        Card {
            EffectHeader(title: "EQ", subtitle: "Three bands for tonal balance", symbol: "slider.vertical.3", enabled: $model.settings.eqEnabled) { model.settings.low = 0; model.settings.mid = 0; model.settings.high = 0; model.settings.eqEnabled = false }
            HStack(spacing: 24) {
                ToneDial(title: "Low", subtitle: "160 Hz shelf", value: $model.settings.low)
                ToneDial(title: "Mid", subtitle: "1 kHz bell · Q 0.8", value: $model.settings.mid)
                ToneDial(title: "High", subtitle: "4 kHz shelf", value: $model.settings.high)
            }
        }
    }
    private var compressorCard: some View {
        Card {
            EffectHeader(title: "Compressor", subtitle: "Smooth level changes · stereo linked", symbol: "arrow.down.right.and.arrow.up.left", enabled: $model.settings.compressorEnabled) { model.settings.threshold = -18; model.settings.ratio = 3; model.settings.attack = 10; model.settings.release = 100; model.settings.compressorEnabled = false }
            Grid(horizontalSpacing: 32, verticalSpacing: 14) {
                GridRow {
                    ParameterSlider(title: "Threshold", value: $model.settings.threshold, range: -48...0, step: 1, unit: "dB", decimals: 0)
                    ParameterSlider(title: "Ratio", value: $model.settings.ratio, range: 1...8, unit: ": 1")
                }
                GridRow {
                    ParameterSlider(title: "Attack", value: $model.settings.attack, range: 1...100, step: 1, unit: "ms", decimals: 0)
                    ParameterSlider(title: "Release", value: $model.settings.release, range: 20...1000, step: 5, unit: "ms", decimals: 0)
                }
            }
            HStack(spacing: 12) {
                Text("Gain reduction").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(24,max(0,model.reduction)), total: 24).tint(voiceAccent)
                Text(String(format: "%.1f dB", model.reduction)).font(.caption.monospaced()).frame(width: 58)
            }
        }
    }
    private var outputCard: some View {
        Card {
            HStack {
                Label("Output", systemImage: "speaker.wave.2").font(.headline)
                Spacer(); Text("Peak protection is always active in effects mode.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Slider(value: $model.settings.volume, in: 0...1, step: 0.01).accessibilityLabel("Playback volume")
                Text("\(Int(model.settings.volume * 100))%").font(.body.monospaced()).frame(width: 46, alignment: .trailing)
                Button { model.settings.volume = 1 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).help("Reset volume")
            }
            Text("Wired or USB headphones recommended. No microphone capture, audio recording, or external audio transmission by this app.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var diagnostics: some View {
        DisclosureGroup("Source verification & diagnostics", isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 10) {
                if let i = model.inspection {
                    Text("App: \(i.appURL.path)\nBundle: \(i.bundleID)\nSigning team: \(i.team)\nApplication PID: \(i.root.pid)")
                    ForEach(i.targets) { t in Text("PID \(t.process.pid) → AudioObjectID \(t.objectID)\n\(t.process.path)\n\(t.runningOutput ? "Output activity detected; this is not call detection." : "No output activity at the last refresh.")") }
                }
                Text(model.statistics)
            }.font(.caption.monospaced()).textSelection(.enabled).padding(.top, 8)
        }.font(.caption).foregroundStyle(.secondary)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { model.start() } label: { Label("Start processing", systemImage: "play.fill").padding(.vertical, 3) }.buttonStyle(.borderedProminent).disabled(!model.canStart)
                Button("Stop & hear original") { model.stop() }.disabled(!model.busy)
                Button("Check route") { model.start(.captureCheck) }.disabled(!model.canStart).help("Capture and replay without connecting the effects. Verify a new device first.")
                Spacer()
                Button { model.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }.help("Emergency stop — Command + period").accessibilityLabel("Emergency stop and restore original audio")
            }
            Text(model.message).font(.caption).foregroundStyle(model.state == .error ? .red : .secondary).textSelection(.enabled)
            if let hint = model.startHint { Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            Text("Development build · Live effects and recovery verification pending").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
