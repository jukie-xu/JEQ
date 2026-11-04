import Foundation

/// 按 CoreAudio 显示名称匹配；同名设备共享配置，UID 变化不会丢失音色。
struct DeviceEQProfile: Codable {
    var name: String
    var state: PersistedState
    var enabled: Bool
    var updatedAt: Date
}

final class DeviceProfileStore {
    struct Document: Codable {
        var version = 1
        var devices: [String: DeviceEQProfile] = [:]
    }

    let url: URL

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JEQ/device-profiles.json")) {
        self.url = url
    }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private func read() throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(Document.self, from: Data(contentsOf: url))
        guard doc.version == 1 else {
            throw NSError(domain: "JEQ", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持的设备配置文件版本"])
        }
        return doc
    }

    func profile(named name: String) throws -> DeviceEQProfile? {
        try read().devices[Self.key(name)]
    }

    func save(name: String, state: PersistedState, enabled: Bool) throws {
        let key = Self.key(name)
        guard !key.isEmpty else { return }
        // 读取失败时保留原文件并报错，禁止用默认值覆盖损坏或未知版本的存档。
        var doc = try read()
        doc.devices[key] = DeviceEQProfile(name: name, state: state, enabled: enabled, updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
