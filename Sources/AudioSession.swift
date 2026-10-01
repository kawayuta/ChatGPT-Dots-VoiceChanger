import Foundation
import AppKit
import AVFAudio
import CoreAudio
import AudioToolbox

enum SessionState: String { case stopped = "Stopped", preparing = "Preparing", checking = "Checking route", running = "Processing", recovering = "Restoring", error = "Error" }
enum SessionMode { case captureCheck, effects }

struct SessionUpdate {
    let state: SessionState
    let message: String
    let stats: CVPStats?
    let dspStats: DVCDSPStats?
    let format: String?
}

// All lifecycle mutations belong to this serial, non-realtime queue. Audio callbacks
// only see the preallocated C bridge. No Swift object, logging, or locks in capture.
final class AudioSession {
    let queue = DispatchQueue(label: "io.github.kawayuta.dotsvoicechanger.lifecycle", qos: .userInitiated)
    var onUpdate: ((SessionUpdate) -> Void)?
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    private var engine: AVAudioEngine?
    private var effects: DVCEffectsAudioUnit?
    private var settings = EffectSettings()
    private var mode: SessionMode = .captureCheck
    private var formatSummary: String?
    private var captureStream: AudioObjectID = 0
    private var bridge: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var inspection: Inspection?
    private var selectedOutput: OutputDevice?
    private var health = SessionHealth(now: ProcessInfo.processInfo.systemUptime)
    private let controlLock = NSLock() // UI/lifecycle only; audio callbacks never touch it.
    private var controlGeneration: UInt64 = 0
    private var state: SessionState = .stopped
    // If the HAL cannot stop/destroy callbacks, retaining buffers is safer than use-after-free.
    private var quarantinedBridges: [OpaquePointer] = []
    private var unsafeToRestart = false

    func inspect(appURL: URL, _ callback: @escaping (Result<Inspection, Error>) -> Void) {
        queue.async { let result = Result { try Inspection.read(appURL: appURL) }; DispatchQueue.main.async { callback(result) } }
    }
    func start(expected: Inspection, outputUID: String, settings: EffectSettings, mode: SessionMode) {
        controlLock.lock(); controlGeneration &+= 1; let generation = controlGeneration; controlLock.unlock()
        queue.async {
            guard self.state == .stopped || self.state == .error else { return }
            guard !self.unsafeToRestart else { self.publish(.error, "Audio cleanup could not be confirmed. Quit and reopen Dots Voice Changer before trying again."); return }
            self.publish(.preparing, "Preparing capture and playback. Approve the macOS audio permission yourself if prompted.")
            do {
                let current = try Inspection.read(appURL: expected.appURL)
                guard !current.competingCaptureOutput else { throw AudioFailure(stage: "Another capture app is playing audio", status: nil, advice: "Stop or quit it, then refresh before starting.") }
                guard current.root == expected.root, current.targets == expected.targets, !current.targets.isEmpty else {
                    throw AudioFailure(stage: "The verified process set changed", status: nil, advice: "Refresh the target and start manually.")
                }
                guard let output = current.outputs.first(where: { $0.uid == outputUID }) else {
                    throw AudioFailure(stage: "Output device not found", status: nil, advice: "Choose the output device again.")
                }
                self.inspection = current; self.selectedOutput = output
                self.settings = settings; self.settings.sanitize(); self.mode = mode
                try self.prepare(current: current, output: output, generation: generation)
            } catch is SessionCancelled {
                self.releaseResources(finalState: .stopped, message: "Startup cancelled. The original process audio is restored.")
            } catch { self.fail(error.localizedDescription) }
        }
    }
    private struct SessionCancelled: Error {}
    private func cancelStartup() { controlLock.lock(); controlGeneration &+= 1; controlLock.unlock() }
    private func checkCancellation(_ generation: UInt64) throws {
        controlLock.lock(); let cancelled = generation != controlGeneration; controlLock.unlock()
        if cancelled { throw SessionCancelled() }
    }
    func stop() { cancelStartup(); queue.async { self.releaseResources(finalState: .stopped, message: "Capture stopped. The original process audio is restored by releasing the tap.") } }
    func stopSynchronously() { cancelStartup(); queue.sync { releaseResources(finalState: .stopped, message: "Capture session ended.") } }
    func setSettings(_ settings: EffectSettings) {
        queue.async {
            self.settings = settings; self.settings.sanitize()
            if let effects = self.effects { effects.apply(self.settings.parameters) }
            if let b = self.bridge { cvp_bridge_set_gain(b, self.mode == .captureCheck ? Float(self.settings.volume) : 1) }
        }
    }

    private func publish(_ next: SessionState, _ message: String, stats: CVPStats? = nil) {
        state = next
        let update = SessionUpdate(state: next, message: message, stats: stats, dspStats: effects?.statistics(), format: formatSummary)
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(update) }
    }
    private func prepare(current: Inspection, output: OutputDevice, generation: UInt64) throws {
        try checkCancellation(generation)
        let description = CATapDescription(stereoMixdownOfProcesses: current.targets.map(\.objectID))
        description.name = "Dots Voice Changer verified process input"
        description.isExclusive = false // Include only verified object IDs. Never a global/excluding tap.
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) { description.isProcessRestoreEnabled = false }
        try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")
        let tapFormat = try HAL.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        let tapUID = try HAL.string(tapID, kAudioTapPropertyUID)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dots Voice Changer private input",
            kAudioAggregateDeviceUIDKey: "io.github.kawayuta.dotsvoicechanger." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        ]
        // Tap-only aggregate: NO physical subdevice, microphone, or global routing.
        try HAL.check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID), "Create private aggregate device")
        try HAL.set(aggregateID, kAudioDevicePropertyNominalSampleRate, tapFormat.mSampleRate)
        let inputStreams = try HAL.objects(aggregateID, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        guard inputStreams.count == 1, let stream = inputStreams.first else {
            throw AudioFailure(stage: "Unsupported capture-stream layout", status: nil, advice: "Multiple input streams have not been validated. Capture was not started.")
        }
        let format = try HAL.value(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
        captureStream = stream
        let rate = format.mSampleRate
        guard rate >= 8000, rate <= 192000 else { throw AudioFailure(stage: "Unsupported sample rate", status: nil, advice: "Capture was not started.") }
        let capacity = UInt32(ceil(rate * 0.25)) + 4096
        guard let b = cvp_bridge_create(format, capacity, UInt32(ceil(rate * 0.040)), UInt32(ceil(rate * 0.120))) else {
            throw AudioFailure(stage: "Unsupported capture PCM format", status: nil, advice: "Only mono/stereo little-endian packed PCM is supported. Capture was not started.")
        }
        bridge = b; cvp_bridge_set_gain(b, mode == .captureCheck ? Float(settings.volume) : 1)
        let engine = AVAudioEngine(); self.engine = engine
        guard let unit = engine.outputNode.audioUnit else { throw AudioFailure(stage: "Output audio unit", status: nil, advice: "Playback could not be prepared.") }
        var deviceID = output.objectID
        try HAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "Select app playback device")
        var actualID: AudioObjectID = 0; var idSize = UInt32(MemoryLayout<AudioObjectID>.size)
        try HAL.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actualID, &idSize), "Verify app playback device")
        guard actualID == output.objectID else { throw AudioFailure(stage: "Playback device does not match", status: nil, advice: "Capture was not started.") }
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else { throw AudioFailure(stage: "Output format", status: nil, advice: "Capture was not started.") }
        let playbackChannels: AVAudioChannelCount = outputFormat.channelCount == 1 ? 1 : 2
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: playbackChannels, interleaved: false) else {
            throw AudioFailure(stage: "Playback PCM format", status: nil, advice: "Capture was not started.")
        }
        let source = AVAudioSourceNode(format: sourceFormat) { isSilence, _, frames, output in
            var silent = true
            let status = cvp_bridge_render(b, frames, output, &silent)
            isSilence.pointee = ObjCBool(silent)
            return status
        }
        engine.attach(source)
        if mode == .effects {
            let node = try EffectsFactory.make()
            guard let unit = node.auAudioUnit as? DVCEffectsAudioUnit else { throw AudioFailure(stage: "Effects type", status: nil, advice: "Capture was not started.") }
            self.effects = unit
            unit.apply(settings.parameters)
            engine.attach(node)
            engine.connect(source, to: node, format: sourceFormat)
            engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
        } else { engine.connect(source, to: engine.mainMixerNode, format: sourceFormat) }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        formatSummary = "Tap \(Int(tapFormat.mSampleRate)) Hz / \(tapFormat.mChannelsPerFrame) ch\nCapture \(Int(rate)) Hz / \(format.mChannelsPerFrame) ch / \(format.mBitsPerChannel) bit\nPlayback \(Int(outputFormat.sampleRate)) Hz / \(outputFormat.channelCount) ch\nBuffer headroom 40 ms + current render quantum\nSpeech DSP: Signalsmith · 80 ms algorithmic window (not device latency)"
        engine.prepare()
        try checkCancellation(generation)
        try engine.start() // Playback must run before mutedWhenTapped starts reading.
        let captureProc: AudioDeviceIOProc = { device, now, input, inputTime, output, outputTime, context in
            cvp_capture_callback(device, now, input, inputTime, output, outputTime, context)
        }
        try HAL.check(AudioDeviceCreateIOProcID(aggregateID, captureProc, UnsafeMutableRawPointer(b), &ioProc), "Create capture IOProc")
        guard let ioProc else { throw AudioFailure(stage: "Capture IOProc", status: nil, advice: "Capture was not started.") }
        try checkCancellation(generation)
        try HAL.check(AudioDeviceStart(aggregateID, ioProc), "Start capture (macOS system-audio permission required)")
        started = true
        try checkCancellation(generation)
        health = SessionHealth(now: ProcessInfo.processInfo.systemUptime)
        try installMonitoring(output: output, engine: engine)
        publish(.preparing, "Checking capture and playback callbacks. Please verify that voice is audible once and that Stop restores the original audio.")
    }

    private func installMonitoring(output: OutputDevice, engine: AVAudioEngine) throws {
        let notify: (Notification) -> Void = { [weak self] _ in self?.queue.async { self?.fail("Sleep, wake, or an audio-engine configuration change was detected. Refresh the target and start manually.") } }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: notify))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil, using: notify))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil, using: notify))
        try addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        try addListener(output.objectID, kAudioDevicePropertyDeviceIsAlive)
        try addListener(output.objectID, kAudioDevicePropertyNominalSampleRate)
        try addListener(output.objectID, kAudioDevicePropertyBufferFrameSize)
        try addListener(tapID, kAudioTapPropertyFormat)
        try addListener(captureStream, kAudioStreamPropertyVirtualFormat)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.monitor() }
        self.timer = timer; timer.resume()
    }
    private func addListener(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws {
        var address = HAL.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.started else { return }
            self.fail("An output device or system default changed. Capture stopped; refresh and start manually.")
        }
        let status = AudioObjectAddPropertyListenerBlock(id, &address, queue, block)
        if status == noErr { listeners.append((id, address, block)) }
        else { throw AudioFailure(stage: "Monitor device changes", status: status, advice: "Startup was rolled back.") }
    }
    private func monitor() {
        guard started, let b = bridge, let old = inspection else { return }
        let stats = cvp_bridge_stats(b)
        let snapshot = AudioHealthSnapshot(capture: stats.capture_callbacks, render: stats.render_callbacks,
            underflows: stats.underflows, overflows: stats.overflows, resets: stats.backlog_resets,
            formatErrors: stats.format_errors, invalidSamples: effects?.statistics().nonfinite_samples ?? 0)
        if let reason = health.failure(snapshot, engineRunning: engine?.isRunning == true, now: ProcessInfo.processInfo.systemUptime) {
            fail(reason + " Releasing the tap to restore the original audio."); return
        }
        do {
            let current = try Inspection.read(appURL: old.appURL)
            guard current.root == old.root, current.targets == old.targets,
                  let output = selectedOutput, current.outputs.contains(output) else {
                fail("The verified process set or output device changed. Capture stopped. Refresh and start manually; the target set is never expanded automatically.")
                return
            }
        } catch { fail(error.localizedDescription); return }
        if stats.capture_callbacks > 0 && stats.render_callbacks > 0 {
            publish(mode == .captureCheck ? .checking : .running, mode == .captureCheck ? "Capture check: effects are bypassed. Stop releases the tap for comparison with the original." : "Processing verified ChatGPT process audio. Same-process notifications may also be processed. Call state is not detected automatically.", stats: stats)
        }
    }
    private func fail(_ message: String) {
        guard state != .recovering, state != .stopped else { return }
        releaseResources(finalState: .error, message: message)
    }
    private func releaseResources(finalState: SessionState, message: String) {
        publish(.recovering, "Stopping callbacks and releasing private audio resources.")
        timer?.cancel(); timer = nil
        for (id, original, block) in listeners {
            var a = original; AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
        }
        listeners.removeAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if let b = bridge { cvp_bridge_silence(b) }
        // Stop processed playback before releasing the original process's mute:
        // buffered DSP tails must not overlap newly restored original audio.
        engine?.stop(); engine = nil; effects = nil
        var teardownErrors: [String] = []
        var callbacksStopped = true
        if let ioProc {
            if started {
                let status = AudioDeviceStop(aggregateID, ioProc)
                if status != noErr { teardownErrors.append("Stop capture \(status)"); callbacksStopped = false }
            }
            let status = AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            if status != noErr { teardownErrors.append("Destroy IOProc \(status)"); callbacksStopped = false }
            self.ioProc = nil
        }
        started = false
        if !callbacksStopped && tapID != 0 {
            // Emergency unmute fallback through the public tap description property.
            var desc: CATapDescription?
            var a = HAL.address(kAudioTapPropertyDescription); var size = UInt32(MemoryLayout<CATapDescription?>.size)
            let get = withUnsafeMutablePointer(to: &desc) { AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, $0) }
            if get == noErr, let desc {
                desc.muteBehavior = .unmuted
                var value: CATapDescription? = desc
                let set = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(tapID, &a, 0, nil, size, $0) }
                if set != noErr { teardownErrors.append("Emergency unmute \(set)") }
            } else { teardownErrors.append("Prepare emergency unmute \(get)") }
        }
        if aggregateID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr { teardownErrors.append("Destroy aggregate \(status)") }
            aggregateID = 0
        }
        if tapID != 0 {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr { teardownErrors.append("Destroy tap \(status)") }
            tapID = 0
        }
        if let b = bridge {
            if callbacksStopped { cvp_bridge_destroy(b) } else { quarantinedBridges.append(b) }
            bridge = nil
        }
        inspection = nil; selectedOutput = nil
        captureStream = 0; formatSummary = nil
        if teardownErrors.isEmpty { publish(finalState, message) }
        else { unsafeToRestart = true; publish(.error, message + " Cleanup errors: " + teardownErrors.joined(separator: ", ") + ". Check the original audio and quit this prototype.") }
    }
}
