import Foundation
import AppKit
import CoreAudio
import Security

struct AudioFailure: LocalizedError {
    let stage: String
    let status: OSStatus?
    let advice: String
    var errorDescription: String? {
        "\(stage)\(status.map { " (OSStatus \($0))" } ?? ""). \(advice)"
    }
}

enum HAL {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ stage: String) throws {
        if status != noErr { throw AudioFailure(stage: stage, status: status, advice: "Capture will stop to restore the original audio. Check the audio-capture permission and output device.") }
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var a = address(selector, scope); var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &result) { p in
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, p), "Read audio property \(selector)")
        }
        return result
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var a = address(selector); var result: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        try withUnsafeMutablePointer(to: &result) { p in
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, p), "Read audio identifier")
        }
        return result as String? ?? ""
    }
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var a = address(selector, scope); var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "Read audio list size")
        guard size > 0 else { return [] }
        guard size % 4 == 0 else { throw AudioFailure(stage: "Unexpected audio list format", status: nil, advice: "Capture was not started.") }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        try result.withUnsafeMutableBytes { p in
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, p.baseAddress!), "Read audio object list")
        }
        return Array(result.prefix(Int(size) / 4))
    }
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var a = address(selector); a.mScope = scope; var v = value
        try withUnsafePointer(to: &v) { p in
            try check(AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), p), "Configure private audio device \(selector)")
        }
    }
}

struct ProcessIdentity: Equatable {
    let pid: Int32
    let parent: Int32
    let seconds: UInt64
    let microseconds: UInt64
    let path: String
    static func read(_ pid: Int32) throws -> Self {
        var bytes = [CChar](repeating: 0, count: 4096)
        var parent: Int32 = 0; var sec: UInt64 = 0; var usec: UInt64 = 0
        guard cvp_process_path(pid, &bytes, UInt32(bytes.count)) > 0,
              cvp_process_identity(pid, &parent, &sec, &usec) != 0 else {
            throw AudioFailure(stage: "Cannot verify process \(pid)", status: nil, advice: "The target may have exited. Capture was not started.")
        }
        return Self(pid: pid, parent: parent, seconds: sec, microseconds: usec,
                    path: URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path)
    }
}

struct Signature {
    let identifier: String
    let team: String
    static func info(_ code: SecStaticCode) throws -> Self {
        var data: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &data)
        guard status == errSecSuccess, let dict = data as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              let id = dict[kSecCodeInfoIdentifier as String] as? String else {
            throw AudioFailure(stage: "Cannot read code-signing identity", status: status, advice: "Unverified processes are never captured.")
        }
        return Self(identifier: id, team: team)
    }
    static func installed(_ url: URL) throws -> Self {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw AudioFailure(stage: "Cannot read application signature", status: status, advice: "Select the official ChatGPT desktop app.") }
        let valid = SecStaticCodeCheckValidity(code, [], nil)
        guard valid == errSecSuccess else { throw AudioFailure(stage: "Application signature validation failed", status: valid, advice: "Capture was not started.") }
        return try info(code)
    }
    static func running(_ pid: Int32) throws -> Self {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let status = SecCodeCopyGuestWithAttributes(nil, attrs, [], &code)
        guard status == errSecSuccess, let code else { throw AudioFailure(stage: "Cannot read process signature", status: status, advice: "Capture was not started.") }
        let valid = SecCodeCheckValidity(code, [], nil)
        guard valid == errSecSuccess else { throw AudioFailure(stage: "Process signature validation failed", status: valid, advice: "Capture was not started.") }
        var staticCode: SecStaticCode?
        let copied = SecCodeCopyStaticCode(code, [], &staticCode)
        guard copied == errSecSuccess, let staticCode else { throw AudioFailure(stage: "Cannot inspect process signature", status: copied, advice: "Capture was not started.") }
        return try info(staticCode)
    }
}

struct AudioTarget: Equatable, Identifiable {
    let objectID: AudioObjectID
    let process: ProcessIdentity
    let bundleID: String
    let signingID: String
    let runningOutput: Bool
    var id: AudioObjectID { objectID }
    static func ==(a: Self, b: Self) -> Bool {
        // Output activity is not a call-state API and is not part of the lifetime fingerprint.
        a.objectID == b.objectID && a.process == b.process && a.bundleID == b.bundleID && a.signingID == b.signingID
    }
}

struct OutputDevice: Identifiable, Equatable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let sampleRate: Double
    var id: String { uid }
}

struct Inspection {
    let appURL: URL
    let version: String
    let build: String
    let bundleID: String
    let root: ProcessIdentity
    let team: String
    let targets: [AudioTarget]
    let outputs: [OutputDevice]
    let defaultOutput: AudioObjectID
    let competingCaptureOutput: Bool

    static let verifiedOpenAITeam = "2DC432GLL2" // Public signing identity of the verified official desktop app.

    static func otherCaptureIsPlaying() throws -> Bool {
        let peers = ["local.chatgptvoicepitch.prototype", "io.github.kawayuta.DotsVoiceChanger"]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { !$0.isTerminated && $0.processIdentifier != getpid() }
        let pids = Set(peers.map(\.processIdentifier))
        guard !pids.isEmpty else { return false }
        for id in try HAL.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            let pid = Int32(bitPattern: try HAL.value(id, kAudioProcessPropertyPID, initial: UInt32(0)))
            if pids.contains(pid), try HAL.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) != 0 { return true }
        }
        return false
    }

    static func recommendedAppURL() -> URL? {
        // This is only a discovery hint. Signature, executable, ancestry, and live identity
        // are still verified before capture. A name alone never grants access.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") { return url }
        for application in NSWorkspace.shared.runningApplications {
            guard let url = application.bundleURL,
                  let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                  name == "ChatGPT" || name == "Codex",
                  let signature = try? Signature.installed(url), signature.team == verifiedOpenAITeam else { continue }
            return url
        }
        return nil
    }

    static func read(appURL: URL) throws -> Self {
        let url = appURL.resolvingSymlinksInPath()
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
              let executable = bundle.executableURL?.resolvingSymlinksInPath() else {
            throw AudioFailure(stage: "Target application not found", status: nil, advice: "Choose the installed official ChatGPT desktop app.")
        }
        let signature = try Signature.installed(url)
        let productName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        guard signature.team == verifiedOpenAITeam, signature.identifier == bundleID,
              productName == "ChatGPT" || productName == "Codex" else {
            throw AudioFailure(stage: "The application does not match the verified OpenAI signing identity", status: nil, advice: "Capture was not started.")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.bundleURL?.resolvingSymlinksInPath() == url && !$0.isTerminated
        }
        guard running.count == 1, let app = running.first else {
            throw AudioFailure(stage: "The selected app is not running or is ambiguous", status: nil, advice: "Open it, start your desktop voice call, then refresh.")
        }
        let root = try ProcessIdentity.read(app.processIdentifier)
        guard root.path == executable.path, try Signature.running(root.pid).team == signature.team else {
            throw AudioFailure(stage: "Cannot verify the running application", status: nil, advice: "The executable path and signing identity must match the selected app.")
        }
        let contents = url.appendingPathComponent("Contents", isDirectory: true).path + "/"
        var targets: [AudioTarget] = []
        for id in try HAL.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            let pid = Int32(bitPattern: try HAL.value(id, kAudioProcessPropertyPID, initial: UInt32(0)))
            guard pid != getpid(), let identity = try? ProcessIdentity.read(pid), identity.path.hasPrefix(contents) else { continue }
            var parent = identity.pid; var belongs = false
            for _ in 0..<16 {
                if parent == root.pid { belongs = true; break }
                guard parent > 1, let ancestor = try? ProcessIdentity.read(parent), ancestor.parent != parent else { break }
                parent = ancestor.parent
            }
            guard belongs else { continue }
            let signed = try Signature.running(pid)
            guard signed.team == signature.team else { continue }
            let halBundle = try HAL.string(id, kAudioProcessPropertyBundleID)
            // HAL IDs and signing IDs can differ on macOS helpers. Path, ancestry, and signature
            // must all match; neither an app name nor the HAL bundle string grants access.
            let active = try HAL.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) != 0
            targets.append(AudioTarget(objectID: id, process: identity, bundleID: halBundle, signingID: signed.identifier, runningOutput: active))
        }
        targets.sort { $0.objectID < $1.objectID }
        var outputs: [OutputDevice] = []
        for id in try HAL.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
            guard !(try HAL.objects(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)).isEmpty else { continue }
            let uid = try HAL.string(id, kAudioDevicePropertyDeviceUID)
            guard !uid.hasPrefix("local.chatgptvoicepitch."), !uid.hasPrefix("io.github.kawayuta.dotsvoicechanger.") else { continue }
            let rate = try HAL.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
            outputs.append(OutputDevice(objectID: id, uid: uid, name: try HAL.string(id, kAudioObjectPropertyName), sampleRate: rate))
        }
        let defaultOutput = try HAL.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        return Self(appURL: url, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
                    build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown", bundleID: bundleID, root: root,
                    team: signature.team, targets: targets, outputs: outputs, defaultOutput: defaultOutput,
                    competingCaptureOutput: try otherCaptureIsPlaying())
    }
}
