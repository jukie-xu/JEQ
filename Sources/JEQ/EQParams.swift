import Foundation

// MARK: - 控制点

/// 图形 EQ 的控制点：横向是频率，纵向是目标增益。
/// 曲线由相邻控制点插值得到，拖动一个点只会改变它到左右邻居之间的曲线。
struct Band: Codable, Identifiable, Equatable {
    var id: UUID
    var freq: Float
    var gainDB: Float
    var enabled: Bool

    init(id: UUID = UUID(), freq: Float, gainDB: Float, enabled: Bool = true) {
        self.id = id
        self.freq = freq
        self.gainDB = gainDB
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, freq, gainDB, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let f = try c.decodeIfPresent(Float.self, forKey: .freq) ?? 1_000
        let g = try c.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0
        freq = f.isFinite ? min(max(f, EQSettings.freqRange.lowerBound), EQSettings.freqRange.upperBound) : 1_000
        gainDB = g.isFinite ? min(max(g, EQSettings.gainRange.lowerBound), EQSettings.gainRange.upperBound) : 0
    }
}

// MARK: - 参数集

/// 控制点布局。自由模式保留老版本的可拖频率曲线；标准模式固定为
/// 业界常用的 10 段中心频率，只允许调增益，避免用户误把频段整体移走。
enum BandLayout: String, Codable, CaseIterable {
    case freeform
    case standard10

    var title: String {
        switch self {
        case .freeform: return "自由曲线"
        case .standard10: return "标准 10 段"
        }
    }
}

struct EQSettings: Codable, Equatable {
    /// 可拖动的控制点上限（显示层）
    static let maxBands = 10
    static let freqRange: ClosedRange<Float> = 20...20_000
    static let gainRange: ClosedRange<Float> = -18...18

    /// 音频行业常见的图形 EQ 分段。固定中心频率比“随手拖点”更容易
    /// 在不同设备、不同节目之间复现同一套声音。
    static let standardFrequencies: [Float] = [
        31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    var bands: [Band]
    var bandLayout: BandLayout = .freeform
    var bass: BassSettings = .init()
    /// 独立的 2–6 kHz 清晰度模块；0 表示关闭。
    var clarityDB: Float = 0

    var preampDB: Float = 0
    var autoPreamp: Bool = true
    var trimDB: Float = 0
    var limiter: Bool = true
    /// 大音量护耳：开启后由独立的峰值限制器把输出控制在上限以内。
    /// 默认关闭，避免改变现有音色和响度。
    var hearingGuard: Bool = false
    var hearingCeilingDB: Float = -6

    init() {
        bands = Self.standardFrequencies.map { Band(freq: $0, gainDB: 0) }
        bandLayout = .standard10
    }

    enum CodingKeys: String, CodingKey {
        case bands, bandLayout, bass, clarityDB
        case preampDB, autoPreamp, trimDB, limiter, hearingGuard, hearingCeilingDB
        // 旧版（固定 4 段参数 EQ）存档
        case subDB, bassDB, midDB, airDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preampDB = try c.decodeIfPresent(Float.self, forKey: .preampDB) ?? 0
        autoPreamp = try c.decodeIfPresent(Bool.self, forKey: .autoPreamp) ?? true
        trimDB = try c.decodeIfPresent(Float.self, forKey: .trimDB) ?? 0
        limiter = try c.decodeIfPresent(Bool.self, forKey: .limiter) ?? true
        hearingGuard = try c.decodeIfPresent(Bool.self, forKey: .hearingGuard) ?? false
        hearingCeilingDB = try c.decodeIfPresent(Float.self, forKey: .hearingCeilingDB) ?? -6
        bandLayout = try c.decodeIfPresent(BandLayout.self, forKey: .bandLayout) ?? .freeform
        bass = try c.decodeIfPresent(BassSettings.self, forKey: .bass) ?? .init()
        clarityDB = try c.decodeIfPresent(Float.self, forKey: .clarityDB) ?? 0
        if !preampDB.isFinite { preampDB = 0 }
        if !trimDB.isFinite { trimDB = 0 }
        if !hearingCeilingDB.isFinite { hearingCeilingDB = -6 }
        hearingCeilingDB = min(max(hearingCeilingDB, -12), -3)
        if !clarityDB.isFinite { clarityDB = 0 }
        clarityDB = min(max(clarityDB, -6), 6)

        if let decoded = try c.decodeIfPresent([Band].self, forKey: .bands) {
            bands = decoded
        } else {
            // 旧存档只有 4 个增益字段 → 迁移到 4 个控制点
            let sub = try c.decodeIfPresent(Float.self, forKey: .subDB) ?? 0
            let bass = try c.decodeIfPresent(Float.self, forKey: .bassDB) ?? 0
            let mid = try c.decodeIfPresent(Float.self, forKey: .midDB) ?? 0
            let air = try c.decodeIfPresent(Float.self, forKey: .airDB) ?? 0
            bands = [
                Band(freq: 38, gainDB: sub),
                Band(freq: 90, gainDB: bass),
                Band(freq: 180, gainDB: mid),
                Band(freq: 9_000, gainDB: air),
            ]
        }
        if bands.count > Self.maxBands { bands = Array(bands.prefix(Self.maxBands)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bands, forKey: .bands)
        try c.encode(bandLayout, forKey: .bandLayout)
        try c.encode(bass, forKey: .bass)
        try c.encode(clarityDB, forKey: .clarityDB)
        try c.encode(preampDB, forKey: .preampDB)
        try c.encode(autoPreamp, forKey: .autoPreamp)
        try c.encode(trimDB, forKey: .trimDB)
        try c.encode(limiter, forKey: .limiter)
        try c.encode(hearingGuard, forKey: .hearingGuard)
        try c.encode(hearingCeilingDB, forKey: .hearingCeilingDB)
    }

    /// 曲线本身（不含手动 preamp/trim）。启用点按频率排序，相邻点之间用
    /// 余弦缓动插值：每个节点的增益就是曲线在该点的值，且拖动只影响相邻段。
    func eqCurveDB(at freq: Float) -> Float {
        let pts = bands.filter { $0.enabled }.sorted { $0.freq < $1.freq }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if pts.count == 1 { return first.gainDB }
        if freq <= first.freq { return first.gainDB }
        if freq >= last.freq { return last.gainDB }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            guard b.freq > a.freq else { continue }
            if freq <= b.freq {
                let span = log(b.freq / a.freq)
                let t = span > 0 ? log(freq / a.freq) / span : 1
                let s = (1 - cos(Float.pi * t)) / 2
                return a.gainDB + (b.gainDB - a.gainDB) * s
            }
        }
        return last.gainDB
    }

    /// 最终目标曲线 = 固定 EQ + 独立低音模块 + 清晰度模块。
    func effectiveCurveDB(at freq: Float) -> Float {
        eqCurveDB(at: freq) + bass.curveDB(at: freq) + clarityCurveDB(at: freq)
    }

    private func clarityCurveDB(at freq: Float) -> Float {
        guard abs(clarityDB) > 0.01 else { return 0 }
        return SmoothCurve.value(at: freq, points: [
            (20, 0), (800, 0), (1_600, clarityDB * 0.22),
            (2_800, clarityDB * 0.82), (4_000, clarityDB),
            (6_000, clarityDB * 0.68), (10_000, clarityDB * 0.12),
            (20_000, 0)
        ])
    }

    /// 含手动 preamp / trim 的总响应（用于自测；界面曲线不画增益常数）
    func responseDB(at freq: Float, sampleRate: Float) -> Float {
        _ = sampleRate
        return effectivePreampDB + trimDB + effectiveCurveDB(at: freq)
    }

    /// 滤波器组实际会跟随的最高正增益。按对数频率密集采样，避免只在
    /// 控制点上取最大值而漏掉低频模块的峰值。
    var maxBoost: Float {
        var peak: Float = 0
        let n = 1_024
        for i in 0...n {
            let t = Float(i) / Float(n)
            let f = Self.freqRange.lowerBound
                * pow(Self.freqRange.upperBound / Self.freqRange.lowerBound, t)
            peak = max(peak, effectiveCurveDB(at: f))
        }
        return max(0, peak)
    }

    /// 固定（非随歌曲变化）的线性余量。只在曲线/模式改变时重新计算，
    /// 播放过程中绝不根据信号电平改变。正增益被抵消后，软限幅器通常不介入。
    var staticHeadroomDB: Float {
        guard autoPreamp, maxBoost > 0.01 else { return 0 }
        return -(maxBoost + (limiter ? 0.35 : 0.5))
    }

    /// 兼容旧存档字段名：现在按最终曲线的最大正增益做固定预衰减，
    /// 而不是按当前歌曲/电平自动调整。
    var effectivePreampDB: Float {
        staticHeadroomDB + preampDB
    }
}

// MARK: - ViPER 风格的低音模块

enum BassMode: String, Codable, CaseIterable, Identifiable {
    case off
    case natural
    case pure
    case subwoofer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .natural: return "自然低音"
        case .pure: return "纯低音+"
        case .subwoofer: return "超低音"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: return "关"
        case .natural: return "自然"
        case .pure: return "纯低音"
        case .subwoofer: return "超低音"
        }
    }

    var summary: String {
        switch self {
        case .off: return "关闭独立低音模块"
        case .natural: return "宽而厚实的低频，兼顾鼓点和人声自然度"
        case .pure: return "更集中、更干净的低频，减少中低频浑浊"
        case .subwoofer: return "强化 20–80 Hz 下潜，适合电影和重低音音乐"
        }
    }
}

enum BassStrength: String, Codable, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "轻"
        case .medium: return "中"
        case .high: return "强"
        }
    }

    var peakDB: Float {
        switch self {
        case .low: return 3
        case .medium: return 5.5
        case .high: return 8
        }
    }
}

struct BassSettings: Codable, Equatable {
    var mode: BassMode = .off
    var centerHz: Float = 80
    var strength: BassStrength = .medium

    static let centers: [Float] = [40, 60, 80, 100, 125]

    enum CodingKeys: String, CodingKey { case mode, centerHz, strength }

    init(mode: BassMode = .off, centerHz: Float = 80, strength: BassStrength = .medium) {
        self.mode = mode
        self.centerHz = centerHz
        self.strength = strength
        normalize()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(BassMode.self, forKey: .mode) ?? .off
        centerHz = try c.decodeIfPresent(Float.self, forKey: .centerHz) ?? 80
        strength = try c.decodeIfPresent(BassStrength.self, forKey: .strength) ?? .medium
        normalize()
    }

    private mutating func normalize() {
        if !centerHz.isFinite { centerHz = 80 }
        if let nearest = Self.centers.min(by: { abs($0 - centerHz) < abs($1 - centerHz) }) {
            centerHz = nearest
        }
    }

    /// 三种低音性格使用不同宽度和衰减的中低频轮廓，而不是把所有低频
    /// 一起拉高。强档也只有 8 dB 峰值，避免社区常见的 +10/+8/+6 叠加爆音。
    func curveDB(at freq: Float) -> Float {
        guard mode != .off, freq > 1, centerHz > 1 else { return 0 }
        let p = strength.peakDB
        let c = centerHz
        let points: [(Float, Float)]

        switch mode {
        case .off:
            return 0
        case .natural:
            points = [
                (20, 0),
                (max(20, c * 0.38), p * 0.28),
                (c * 0.72, p * 0.76),
                (c, p),
                (c * 1.55, p * 0.67),
                (c * 2.6, p * 0.24),
                (c * 5.0, 0),
                (20_000, 0)
            ]
        case .pure:
            points = [
                (20, p * 0.12),
                (c * 0.45, p * 0.72),
                (c * 0.82, p * 0.96),
                (c, p),
                (c * 1.32, p * 0.62),
                (c * 2.1, p * 0.12),
                (c * 3.2, -p * 0.12),
                (c * 5.0, 0),
                (20_000, 0)
            ]
        case .subwoofer:
            points = [
                (20, p * 0.52),
                (c * 0.38, p * 0.88),
                (c * 0.65, p),
                (c * 0.9, p * 0.94),
                (c * 1.45, p * 0.34),
                (c * 2.2, 0),
                (20_000, 0)
            ]
        }

        return SmoothCurve.value(at: min(max(freq, 20), 20_000), points: points)
    }
}

/// 对数频率轴上的平滑插值。端点外取端点值，避免低频模块在边界突然跳变。
enum SmoothCurve {
    static func value(at freq: Float, points: [(Float, Float)]) -> Float {
        let sorted = points.sorted { $0.0 < $1.0 }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if freq <= first.0 { return first.1 }
        if freq >= last.0 { return last.1 }
        for i in 1..<sorted.count {
            let a = sorted[i - 1], b = sorted[i]
            guard b.0 > a.0, freq <= b.0 else { continue }
            let span = log(b.0 / a.0)
            let t = span > 0 ? log(freq / a.0) / span : 1
            let s = (1 - cos(Float.pi * min(max(t, 0), 1))) / 2
            return a.1 + (b.1 - a.1) * s
        }
        return last.1
    }
}

// MARK: - 整条曲线移动

/// 抓曲线本体时的整体变换。偏移量先夹到「所有节点都不越界」的范围再统一应用，
/// 因此每个节点拿到的是同一个 dB 增量 / 同一个频率比例，曲线形状严格保持；
/// 碰到边界时整条曲线停住，而不是逐个节点被压扁。
enum CurveShift {
    static func apply(_ baseline: [Band], deltaDB: Float, ratio: Float) -> [Band] {
        guard !baseline.isEmpty else { return baseline }
        var out = baseline
        if abs(deltaDB) > 1e-6 {
            let limits = allowedDeltaDB(baseline)
            let d = min(max(deltaDB, limits.lowerBound), limits.upperBound)
            for i in out.indices { out[i].gainDB += d }
        }
        if abs(ratio - 1) > 1e-9 {
            let limits = allowedRatio(baseline)
            let r = min(max(ratio, limits.lowerBound), limits.upperBound)
            for i in out.indices { out[i].freq *= r }
        }
        return out
    }

    static func allowedDeltaDB(_ baseline: [Band]) -> ClosedRange<Float> {
        guard let lo = baseline.map(\.gainDB).min(),
              let hi = baseline.map(\.gainDB).max() else { return 0...0 }
        return (EQSettings.gainRange.lowerBound - lo)...(EQSettings.gainRange.upperBound - hi)
    }

    static func allowedRatio(_ baseline: [Band]) -> ClosedRange<Float> {
        guard let lo = baseline.map(\.freq).min(),
              let hi = baseline.map(\.freq).max() else { return 1...1 }
        let low = EQSettings.freqRange.lowerBound / max(lo, 1)
        let high = EQSettings.freqRange.upperBound / max(hi, 1)
        return low...max(high, low)
    }
}

// MARK: - 场景预设（只读模板）

/// 面向普通用户的场景模式。频点固定为标准 10 段；低音不是简单地把
/// 第一段拉高，而是由独立的低音模块承担，和 ViPER 的分层方式一致。
enum ScenePreset: String, CaseIterable, Identifiable, Hashable, Codable {
    case music, movies, games, speech, heavyBass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "音乐"
        case .movies: return "电影"
        case .games: return "游戏"
        case .speech: return "人声"
        case .heavyBass: return "重低音"
        }
    }

    var summary: String {
        switch self {
        case .music: return "自然均衡，轻微低频厚度与人声细节"
        case .movies: return "影院式低频和动态，对白仍保持清晰"
        case .games: return "突出脚步、环境低频与空间细节"
        case .speech: return "压低低频噪声，提升 2–6 kHz 语音清晰度"
        case .heavyBass: return "ViPER 风格低频：独立超低音模块，强而少浑浊"
        }
    }

    /// 标准 10 段基础曲线；低频量感主要由 BassSettings 再叠加。
    var gains: [Float] {
        switch self {
        case .music:
            return [0, 0.5, 0.5, 0, -0.5, 0, 0.5, 1, 0.5, 0]
        case .movies:
            return [-0.5, 0.5, 1, 0.5, -1, -0.5, 0.5, 1.5, 1, 0]
        case .games:
            return [0, 0.5, 1, 0.5, -1, 0, 1, 1.5, 0.5, 0]
        case .speech:
            return [-3, -3, -2, 0, 1, 2, 3, 2, 0.5, 0]
        case .heavyBass:
            return [0, 1, 2, 2, 1, 0, 0.5, 0.5, 0, 0]
        }
    }

    var defaultBass: BassSettings {
        switch self {
        case .music: return BassSettings(mode: .natural, centerHz: 80, strength: .low)
        case .movies: return BassSettings(mode: .natural, centerHz: 60, strength: .medium)
        case .games: return BassSettings(mode: .pure, centerHz: 80, strength: .low)
        case .speech: return BassSettings()
        case .heavyBass: return BassSettings(mode: .subwoofer, centerHz: 60, strength: .high)
        }
    }

    var defaultClarityDB: Float {
        switch self {
        case .speech: return 1.5
        case .games: return 0.5
        case .movies: return 0.25
        default: return 0
        }
    }

    var bands: [Band] {
        zip(EQSettings.standardFrequencies, gains).map {
            Band(freq: $0.0, gainDB: $0.1)
        }
    }

    func apply(to s: inout EQSettings) {
        s.bands = bands
        s.bandLayout = .standard10
        s.bass = defaultBass
        s.clarityDB = defaultClarityDB
    }
}

// MARK: - 经典预设（兼容旧版本）

enum Preset: String, CaseIterable, Identifiable, Hashable, Codable {
    case flat, bassBoost, deepSub, punch, warm, cinema

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: return "直通"
        case .bassBoost: return "低音增强"
        case .deepSub: return "深潜"
        case .punch: return "打击感"
        case .warm: return "暖厚"
        case .cinema: return "影院"
        }
    }

    var summary: String {
        switch self {
        case .flat: return "不动频响"
        case .bassBoost: return "25–102Hz 集中增强低频，保留人声清晰度"
        case .deepSub: return "20–102Hz 更重的下潜，低频最猛的一档"
        case .punch: return "40–200Hz 加厚，鼓点更实、人声不浑"
        case .warm: return "低中频整体加厚，修薄声与齿音重的耳机"
        case .cinema: return "低频重、中频略收，对白保持清晰"
        }
    }

    /// (频率, 目标增益)，按频率升序
    var curve: [(Float, Float)] {
        switch self {
        case .flat:
            return [(20, 0), (40, 0), (70, 0), (110, 0), (200, 0), (600, 0), (2_400, 0), (9_000, 0)]
        case .bassBoost:
            // 原始音色曲线；防破音只由 auto preamp / limiter 处理，不缩 EQ。
            return [(25, 14.7), (36, 15.3), (59.5, 15.5), (102, 14.1),
                    (165, 7.6), (479, 4.0), (2_400, 3.0), (9_020, 2.2)]
        case .deepSub:
            return [(20, 15), (36, 16), (59.5, 15), (102, 12),
                    (165, 6), (479, 3), (2_400, 2.5), (9_020, 2)]
        case .punch:
            return [(20, 5), (40, 8), (70, 10), (110, 9), (200, 7), (600, 2), (2_400, 4), (9_000, 2)]
        case .warm:
            return [(20, 4), (40, 6), (70, 7), (110, 6), (200, 6), (600, 3), (2_400, 2), (9_000, 0)]
        case .cinema:
            return [(20, 9), (40, 12), (70, 12), (110, 8), (200, 3), (600, 1), (2_400, 4), (9_000, 3)]
        }
    }

    /// 每次取用都生成全新的 Band（新 UUID）：预设永远只读
    var bands: [Band] {
        curve.map { Band(freq: $0.0, gainDB: $0.1) }
    }

    func apply(to s: inout EQSettings) {
        s.bands = bands
        s.bandLayout = .freeform
        s.bass = BassSettings()
        s.clarityDB = 0
    }
}

/// 常驻的「自定义」卡。除曲线外还保存独立低音/清晰度模块，
/// 这样从场景模式改出来的声音也能原样载回。
struct CustomSlot: Codable, Equatable {
    var bands: [Band]
    var base: Preset?
    var sceneBase: ScenePreset? = nil
    var bass: BassSettings? = nil
    var clarityDB: Float? = nil
    var bandLayout: BandLayout? = nil
}

/// 整份存档：settings / 当前来源 / 自定义卡 一次编码、一次写入。
struct PersistedState: Codable {
    var settings: EQSettings
    var profile: ProfileRef
    var customSlot: CustomSlot?
}

// MARK: - 当前配置来源

enum ProfileRef: Equatable {
    case scene(ScenePreset)
    case preset(Preset)
    case custom(base: Preset?, scene: ScenePreset? = nil)

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var basePreset: Preset? {
        if case let .custom(base, _) = self { return base }
        return nil
    }

    var baseScene: ScenePreset? {
        if case let .custom(_, scene) = self { return scene }
        return nil
    }

    var scenePreset: ScenePreset? {
        if case let .scene(scene) = self { return scene }
        return nil
    }

    var title: String {
        switch self {
        case let .scene(scene): return scene.title
        case let .preset(p): return p.title
        case let .custom(base, scene):
            if let scene { return "自定义 · \(scene.title)" }
            return base.map { "自定义 · \($0.title)" } ?? "自定义"
        }
    }
}

extension ProfileRef: Codable {
    private enum CodingKeys: String, CodingKey { case kind, base, scene }
    private enum Kind: String, Codable { case scene, preset, custom }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let base = (try c.decodeIfPresent(String.self, forKey: .base)).flatMap(Preset.init(rawValue:))
        let scene = (try c.decodeIfPresent(String.self, forKey: .scene)).flatMap(ScenePreset.init(rawValue:))
        switch kind {
        case .scene: self = .scene(scene ?? .music)
        case .preset: self = .preset(base ?? .flat)
        case .custom: self = .custom(base: base, scene: scene)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .scene(scene):
            try c.encode(Kind.scene, forKey: .kind)
            try c.encode(scene.rawValue, forKey: .scene)
        case let .preset(p):
            try c.encode(Kind.preset, forKey: .kind)
            try c.encode(p.rawValue, forKey: .base)
        case let .custom(base, scene):
            try c.encode(Kind.custom, forKey: .kind)
            try c.encodeIfPresent(base?.rawValue, forKey: .base)
            try c.encodeIfPresent(scene?.rawValue, forKey: .scene)
        }
    }
}

// MARK: - 滤波器组（把目标曲线变成实际的声音）

/// 固定 1/3 倍频程的峰值滤波器组：控制点只是曲线的样子，
/// 声音由这一组固定滤波器去逼近曲线。中心点处迭代补偿相邻滤波器的叠加，
/// 使总响应在滤波器中心频率上贴合目标曲线。
enum FilterBank {
    /// 滤波器互相重叠得比较多，单个滤波器不需要很大增益，
    /// 叠加后的总响应才能平滑地贴合任意曲线。
    static let q: Float = 1.5

    static func centers(sampleRate: Float) -> [Float] {
        var out: [Float] = []
        let limit = min(20_000, sampleRate * 0.49)
        for i in 0...30 {
            let f = 20 * pow(Float(10), Float(i) * 0.1)
            if f > limit { break }
            out.append(f)
        }
        return out
    }

    static func coeffs(for settings: EQSettings, sampleRate: Float) -> [BiquadCoeff] {
        let fs = centers(sampleRate: sampleRate)
        let n = fs.count
        guard n > 0 else { return [] }

        // K[i][j]：第 j 个滤波器增益 1 dB 时，在第 i 个中心频率上的 dB 贡献。
        // 单个滤波器增益都在 ±10 dB 内，dB 域近似线性，直接解线性方程组即可
        // 让叠加后的总响应在中心频率上贴合目标曲线。
        let unitFilters = fs.indices.map {
            BiquadCoeff.peaking(freq: fs[$0], gainDB: 1, q: FilterBank.q, sampleRate: sampleRate)
        }
        var K = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                K[i][j] = unitFilters[j].magnitudeDB(at: fs[i], sampleRate: sampleRate)
            }
        }
        let targets = fs.map { settings.effectiveCurveDB(at: $0) }
        let gains = solve(K, targets).map { min(max($0, -30), 30) }

        return fs.indices.map { i in
            abs(gains[i]) < 0.01
                ? BiquadCoeff.passthrough
                : BiquadCoeff.peaking(freq: fs[i], gainDB: gains[i], q: FilterBank.q, sampleRate: sampleRate)
        }
    }

    /// 高斯消元（部分主元）
    private static func solve(_ a: [[Float]], _ b: [Float]) -> [Float] {
        let n = b.count
        guard n > 0 else { return [] }
        var A = a
        var x = b

        for col in 0..<n {
            var pivot = col
            var best = abs(A[col][col])
            if col + 1 < n {
                for r in (col + 1)..<n {
                    let v = abs(A[r][col])
                    if v > best { best = v; pivot = r }
                }
            }
            guard best > 1e-9 else { continue }
            if pivot != col {
                A.swapAt(pivot, col)
                x.swapAt(pivot, col)
            }
            let pv = A[col][col]
            if col + 1 < n {
                for r in (col + 1)..<n {
                    let factor = A[r][col] / pv
                    if factor == 0 { continue }
                    for c in col..<n {
                        A[r][c] -= factor * A[col][c]
                    }
                    x[r] -= factor * x[col]
                }
            }
        }

        var out = [Float](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = x[row]
            if row + 1 < n {
                for c in (row + 1)..<n {
                    sum -= A[row][c] * out[c]
                }
            }
            let d = A[row][row]
            out[row] = abs(d) > 1e-9 ? sum / d : 0
        }
        return out
    }
}

// MARK: - 实时安全的参数发布

enum DSPLimits {
    /// 静态余量让正常播放停在膝点以下；软限幅只负责极端瞬态。
    static let limiterKnee: Float = 0.975
    static let limiterCeiling: Float = 0.999
    static let outputWarnLevel: Float = 0.99
    static let hearingCeilingOptions: [Float] = [-3, -6, -9, -12]

    @inline(__always)
    static func softLimit(_ y: Float) -> Float {
        if y > limiterKnee {
            return limiterKnee + (limiterCeiling - limiterKnee)
                * tanh((y - limiterKnee) / (limiterCeiling - limiterKnee))
        }
        if y < -limiterKnee {
            return -limiterKnee - (limiterCeiling - limiterKnee)
                * tanh((-y - limiterKnee) / (limiterCeiling - limiterKnee))
        }
        return y
    }
}

/// 大音量护耳使用的立体声联动峰值包络。
/// 攻击瞬时完成，保证当前采样不越过上限；释放很慢，只恢复峰值余量，
/// 不做逐歌曲/逐片段响度归一化。
struct HearingGuardEnvelope {
    private(set) var gain: Float = 1

    mutating func reset() { gain = 1 }

    @inline(__always)
    mutating func process(peak: Float, ceiling: Float, releaseCoefficient: Float) -> Float {
        let safePeak = max(abs(peak), 1e-9)
        let target = min(1, max(ceiling, 0.001) / safePeak)
        if target < gain {
            gain = target
        } else {
            gain += (target - gain) * min(max(releaseCoefficient, 0), 1)
        }
        return gain
    }
}

/// 音频线程用 trylock + 独立快照缓冲区：永不阻塞、永不读到半个参数集。
/// 竞争失败时沿用上一帧快照，最多滞后一个 buffer（约 10ms）。
final class ParamStore {
    static let maxBands = 32
    static let maxChannels = 8

    private var lock = os_unfair_lock_s()
    private var coeffsPtr: UnsafeMutablePointer<BiquadCoeff>
    private var snapPtr: UnsafeMutablePointer<BiquadCoeff>

    private var count: Int = 0
    private var preamp: Float = 1
    private var makeup: Float = 1
    private var limiter: Bool = true
    private var hearingGuard: Bool = false
    private var hearingCeiling: Float = 0.501187
    private var lastSampleRate: Float = 0

    private var resetRequested = false

    private(set) var snapCount: Int = 0
    private(set) var snapPreamp: Float = 1
    private(set) var snapMakeup: Float = 1
    private(set) var snapLimiter: Bool = true
    private(set) var snapHearingGuard: Bool = false
    private(set) var snapHearingCeiling: Float = 0.501187
    private(set) var snapReset: Bool = false

    init() {
        coeffsPtr = .allocate(capacity: ParamStore.maxBands)
        coeffsPtr.initialize(repeating: .passthrough, count: ParamStore.maxBands)
        snapPtr = .allocate(capacity: ParamStore.maxBands)
        snapPtr.initialize(repeating: .passthrough, count: ParamStore.maxBands)
    }

    deinit {
        coeffsPtr.deinitialize(count: ParamStore.maxBands); coeffsPtr.deallocate()
        snapPtr.deinitialize(count: ParamStore.maxBands); snapPtr.deallocate()
    }

    /// 音频线程只读这里
    var snapshotPointer: UnsafePointer<BiquadCoeff> { UnsafePointer(snapPtr) }

    func publish(_ settings: EQSettings, sampleRate: Float, deviceVolume: Float) {
        _ = deviceVolume   // 实测 tap 为音量前、单元平，无需反算补偿
        let newCoeffs = FilterBank.coeffs(for: settings, sampleRate: sampleRate)
        let pre = pow(10, settings.effectivePreampDB / 20)
        let make = pow(10, settings.trimDB / 20)

        os_unfair_lock_lock(&lock)
        for i in 0..<ParamStore.maxBands {
            coeffsPtr[i] = i < newCoeffs.count ? newCoeffs[i] : .passthrough
        }
        count = newCoeffs.count
        preamp = pre
        makeup = make
        limiter = settings.limiter
        hearingGuard = settings.hearingGuard
        hearingCeiling = pow(10, settings.hearingCeilingDB / 20)
        if sampleRate != lastSampleRate {
            lastSampleRate = sampleRate
            resetRequested = true
        }
        os_unfair_lock_unlock(&lock)
    }

    @inline(__always)
    func refreshSnapshot() {
        if os_unfair_lock_trylock(&lock) {
            snapCount = count
            snapPreamp = preamp
            snapMakeup = makeup
            snapLimiter = limiter
            snapHearingGuard = hearingGuard
            snapHearingCeiling = hearingCeiling
            for i in 0..<ParamStore.maxBands { snapPtr[i] = coeffsPtr[i] }
            snapReset = resetRequested
            resetRequested = false
            os_unfair_lock_unlock(&lock)
        }
    }
}
