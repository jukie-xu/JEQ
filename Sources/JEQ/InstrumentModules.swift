import Foundation

enum InstrumentKind: String, Codable, CaseIterable, Identifiable {
    case drums, strings, piano, vocals
    var id: String { rawValue }
    var title: String {
        switch self {
        case .drums: return "鼓点模块"
        case .strings: return "弦乐模块"
        case .piano: return "钢琴模块"
        case .vocals: return "人声模块"
        }
    }
    var presets: [InstrumentPreset] {
        switch self {
        case .drums: return [.init("底鼓力度", 70, 0.7), .init("军鼓击打", 220, 0.7), .init("镲片细节", 8_000, 0.8)]
        case .strings: return [.init("低弦厚度", 250, 0.9), .init("弓弦质感", 2_500, 0.8), .init("高弦亮度", 6_000, 0.9)]
        case .piano: return [.init("低音共鸣", 120, 0.9), .init("琴体温暖", 500, 0.8), .init("触键颗粒", 3_000, 0.8)]
        case .vocals: return [.init("人声厚度", 250, 0.7), .init("咬字清晰", 3_000, 0.8), .init("空气感", 10_000, 0.9)]
        }
    }
}

struct InstrumentPreset {
    let title: String
    let centerHz: Float
    let widthOctaves: Float
    init(_ title: String, _ centerHz: Float, _ widthOctaves: Float) {
        self.title = title; self.centerHz = centerHz; self.widthOctaves = widthOctaves
    }
}

/// 频段增强，不做声源分离。高斯包络在对数频率轴上平滑叠加到目标频响。
struct InstrumentModule: Codable, Equatable {
    /// 0 为关闭，1–3 为该类乐器的三个预置。
    var preset: Int = 0
    var gainDB: Float = 3

    init(preset: Int = 0, gainDB: Float = 3) {
        self.preset = min(max(preset, 0), 3)
        self.gainDB = gainDB.isFinite ? min(max(gainDB, -6), 6) : 3
    }
    enum CodingKeys: String, CodingKey { case preset, gainDB }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(preset: try c.decodeIfPresent(Int.self, forKey: .preset) ?? 0,
                  gainDB: try c.decodeIfPresent(Float.self, forKey: .gainDB) ?? 3)
    }
    func curveDB(at freq: Float, kind: InstrumentKind) -> Float {
        guard preset > 0, preset <= kind.presets.count, freq > 0 else { return 0 }
        let shape = kind.presets[preset - 1]
        let distance = log2(freq / shape.centerHz) / shape.widthOctaves
        return gainDB * exp(-0.5 * distance * distance)
    }
}

struct InstrumentModules: Codable, Equatable {
    var drums = InstrumentModule()
    var strings = InstrumentModule()
    var piano = InstrumentModule()
    var vocals = InstrumentModule()

    subscript(kind: InstrumentKind) -> InstrumentModule {
        get {
            switch kind {
            case .drums: return drums
            case .strings: return strings
            case .piano: return piano
            case .vocals: return vocals
            }
        }
        set {
            switch kind {
            case .drums: drums = newValue
            case .strings: strings = newValue
            case .piano: piano = newValue
            case .vocals: vocals = newValue
            }
        }
    }
    func curveDB(at freq: Float) -> Float {
        InstrumentKind.allCases.reduce(0) { $0 + self[$1].curveDB(at: freq, kind: $1) }
    }

    init() {}
    enum CodingKeys: String, CodingKey { case drums, strings, piano, vocals }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drums = try c.decodeIfPresent(InstrumentModule.self, forKey: .drums) ?? .init()
        strings = try c.decodeIfPresent(InstrumentModule.self, forKey: .strings) ?? .init()
        piano = try c.decodeIfPresent(InstrumentModule.self, forKey: .piano) ?? .init()
        vocals = try c.decodeIfPresent(InstrumentModule.self, forKey: .vocals) ?? .init()
    }
}
