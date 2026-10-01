import Foundation

struct SoundPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var settings: EffectSettings
}
struct PresetError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
final class PresetStore {
    private struct Document: Codable { var version: Int; var presets: [SoundPreset] }
    private let url: URL
    private(set) var presets: [SoundPreset]
    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else { throw PresetError(message: "This preset file uses an unsupported version. The file has been left unchanged.") }
            guard Set(document.presets.map(\.id)).count == document.presets.count else { throw PresetError(message: "Duplicate preset IDs. The original file has been left unchanged.") }
            presets = document.presets.map { var p = $0; p.settings.sanitize(); return p }
        } else { presets = [] }
    }
    static func applicationURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("io.github.kawayuta.DotsVoiceChanger", isDirectory: true).appendingPathComponent("presets.json")
    }
    func initialPreset(preferredID: UUID?) -> SoundPreset? {
        if let preferredID, let preset = presets.first(where: { $0.id == preferredID }) { return preset }
        return presets.first { $0.name.localizedCaseInsensitiveCompare("Default") == .orderedSame }
    }
    private func checkedName(_ name: String, replacing id: UUID? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64, !trimmed.contains(where: { $0.isNewline }) else { throw PresetError(message: "Use a preset name with 1–64 characters and no line breaks.") }
        guard !presets.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else { throw PresetError(message: "A preset with that name already exists. Choose a different name or update the existing preset.") }
        return trimmed
    }
    private func commit(_ next: [SoundPreset]) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(Document(version: 1, presets: next)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        presets = next // Publish only after successful persistence.
    }
    @discardableResult func save(name: String, settings: EffectSettings) throws -> SoundPreset {
        var safe = settings; safe.sanitize()
        let preset = SoundPreset(id: UUID(), name: try checkedName(name), settings: safe)
        try commit(presets + [preset]); return preset
    }
    func rename(id: UUID, name: String) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw PresetError(message: "Preset no longer exists.") }
        let name = try checkedName(name, replacing: id)
        var next = presets; next[index].name = name; try commit(next)
    }
    func update(id: UUID, settings: EffectSettings) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw PresetError(message: "Preset no longer exists.") }
        var safe = settings; safe.sanitize()
        var next = presets; next[index].settings = safe; try commit(next)
    }
}
