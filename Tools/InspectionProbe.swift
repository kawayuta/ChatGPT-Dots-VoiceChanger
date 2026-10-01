import Foundation

@main struct InspectionProbe {
    static func main() {
        do { try inspect() }
        catch { fputs("Target verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func inspect() throws {
        let chosen = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let appURL = chosen ?? Inspection.recommendedAppURL() else {
            throw AudioFailure(stage: "ChatGPT app not found", status: nil, advice: "Pass the official app bundle path as the first argument.")
        }
        let i = try Inspection.read(appURL: appURL)
        guard !i.targets.isEmpty else { throw AudioFailure(stage: "No verified ChatGPT audio process", status: nil, advice: "Start a desktop voice call and inspect again.") }
        precondition(i.targets.allSatisfy { $0.process.pid != getpid() })
        precondition(Set(i.targets.map(\.objectID)).count == i.targets.count)
        let json: [String: Any] = [
            "capturePerformed": false, "appPath": i.appURL.path, "appVersion": i.version, "appBuild": i.build,
            "bundleID": i.bundleID, "rootPID": i.root.pid, "team": i.team,
            "verifiedTargets": i.targets.map { t -> [String: Any] in
                ["objectID": t.objectID, "pid": t.process.pid, "parentPID": t.process.parent,
                 "path": t.process.path, "halBundleID": t.bundleID, "signingID": t.signingID,
                 "runningOutput": t.runningOutput]
            },
            "verifiedOutputs": i.outputs.map { d -> [String: Any] in ["objectID": d.objectID, "uid": d.uid, "name": d.name, "sampleRate": d.sampleRate] }
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
