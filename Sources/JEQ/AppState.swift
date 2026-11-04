import Foundation
import CoreAudio
import Combine

final class AppState: ObservableObject {
    static let shared = AppState()

    let engine = TapEngine()

    @Published var enabled: Bool {
        didSet {
            guard !suspendPersist else { return }
            persistSettings()
            enabled ? engine.start() : engine.stop()
        }
    }

    @Published var settings: EQSettings {
        didSet {
            persistSettings()
            engine.republish(settings)
        }
    }

    /// 当前编辑对象：出厂预设，或常驻的自定义卡。
    /// 预设永远只读：第一次改频段时自动写入「自定义」卡，之后的修改都落在卡里。
    @Published private(set) var profile: ProfileRef {
        didSet { persistSettings() }
    }

    /// 常驻的自定义卡。切换预设不会清除它，点卡片随时载回。
    /// 在预设上再次改曲线会覆盖它的内容（单卡语义）。
    @Published private(set) var customSlot: CustomSlot? = nil {
        didSet { persistSettings() }
    }

    @Published var showAdvanced: Bool = false
    @Published private(set) var selectedBandID: UUID?
    @Published private(set) var statusLine: String = "未启动"
    @Published private(set) var deviceName: String = "—"
    @Published private(set) var latencyMs: Double = 0
    @Published private(set) var sampleRateText: String = "—"
    @Published private(set) var errorText: String?
    /// 开机启动状态；由 LaunchAtLogin 实际读回，失败时回滚并给出原因
    @Published private(set) var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @Published private(set) var launchAtLoginError: String?

    /// 当前设备 UID 的缓存：拖动曲线时每次改参数都要落盘，
    /// 不能每个事件都去问 CoreAudio。
    private var currentUID: String = ""
    private var currentDeviceName: String = ""
    private let deviceProfiles: DeviceProfileStore
    private var storageError: String?

    /// 诊断命令（--liveproof）期间关闭落盘，避免测试参数覆盖用户配置
    var persistPaused = false

    /// 批量修改 settings + profile + customSlot 时只落盘一次
    private var suspendPersist = false

    private var deviceListener: AudioObjectPropertyListenerBlock?

    init(deviceProfiles: DeviceProfileStore = DeviceProfileStore(),
         initialDevice: (uid: String, name: String)? = nil, observeDevices: Bool = true) {
        self.deviceProfiles = deviceProfiles
        if observeDevices { AppState.migrateLegacyDefaults() }
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "enabled")
        currentUID = initialDevice?.uid ?? TapEngine.uid(of: TapEngine.defaultOutputDevice())
        currentDeviceName = initialDevice?.name ?? TapEngine.name(of: TapEngine.defaultOutputDevice())

        suspendPersist = true
        var initial = EQSettings()
        Preset.flat.apply(to: &initial)
        settings = initial
        profile = .preset(.flat)
        customSlot = nil
        selectedBandID = initial.bands.first?.id

        // 名称文件优先；没有文件时把当前设备的旧 UID 配置迁入。
        loadSettingsForCurrentDevice(allowGlobalMigration: observeDevices)
        suspendPersist = false

        engine.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshStatus() }
        }
        if observeDevices { installDeviceListener() }
    }

    func bootstrap() {
        refreshStatus()
        if enabled { engine.start() }
    }

    // MARK: - 配置 / 预设

    /// 旧版 SubEQ（com.subeq.app）的配置一次性搬到 JEQ（com.jeq.app）：
    /// 只补缺失的键，不覆盖已有配置；旧域保留作为回退。
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        let marker = "jeq.didMigrateFromSubEQ"
        guard !defaults.bool(forKey: marker) else { return }

        var legacyDomain = UserDefaults(suiteName: "com.subeq.app")?
            .persistentDomain(forName: "com.subeq.app") ?? [String: Any]()
        if legacyDomain.isEmpty {
            // 少数情况下 suite 域读不到，直接读旧 plist
            let path = NSHomeDirectory() + "/Library/Preferences/com.subeq.app.plist"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dict = plist as? [String: Any] {
                legacyDomain = dict
            }
        }
        guard !legacyDomain.isEmpty else { return }

        for (key, value) in legacyDomain where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: marker)
    }

    /// 开机启动开关。实际结果以系统状态为准（ad-hoc 签名下可能回退到 LaunchAgent）。
    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginError = LaunchAtLogin.set(on)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    /// 载入出厂预设。预设是只读模板；自定义卡不会因此消失。
    func apply(_ p: Preset) {
        var s = settings
        p.apply(to: &s)
        withBatchedPersist {
            settings = s
            profile = .preset(p)
        }
        selectedBandID = s.bands.first?.id
    }

    /// 载入面向普通用户的场景模式（固定标准 10 段 + 独立低音模块）。
    func apply(_ scene: ScenePreset) {
        var s = settings
        scene.apply(to: &s)
        withBatchedPersist {
            settings = s
            profile = .scene(scene)
        }
        selectedBandID = s.bands.first?.id
    }

    /// 载入常驻的自定义卡
    func applyCustomSlot() {
        guard let slot = customSlot else { return }
        var s = settings
        s.bands = Array(slot.bands.prefix(EQSettings.maxBands))
        s.bandLayout = slot.bandLayout ?? .freeform
        s.bass = slot.bass ?? BassSettings()
        s.clarityDB = min(max(slot.clarityDB ?? 0, -6), 6)
        s.effectStrength = min(max(slot.effectStrength ?? 1, 0), 2)
        s.instruments = slot.instruments ?? InstrumentModules()
        s.moduleOrder = slot.moduleOrder ?? []
        withBatchedPersist {
            settings = s
            profile = .custom(base: slot.base, scene: slot.sceneBase)
        }
        selectedBandID = s.bands.first?.id
    }

    /// 用当前选中的预设覆盖常驻自定义卡，并切到该卡（当前听到的就是新卡）
    func overwriteCustomWithPreset() {
        switch profile {
        case let .scene(scene):
            withBatchedPersist {
                customSlot = makeCustomSlot(from: settings, presetBase: nil, sceneBase: scene)
                profile = .custom(base: nil, scene: scene)
            }
        case let .preset(p):
            withBatchedPersist {
                customSlot = makeCustomSlot(from: settings, presetBase: p, sceneBase: nil)
                profile = .custom(base: p, scene: nil)
            }
        case .custom:
            break
        }
    }

    /// 删除自定义卡；正在使用时退回它基于的预设
    func deleteCustomSlot() {
        guard let slot = customSlot else { return }
        let wasActive = profile.isCustom
        withBatchedPersist { customSlot = nil }
        if wasActive, let scene = slot.sceneBase {
            apply(scene)
        } else if wasActive {
            apply(slot.base ?? .flat)
        }
        if wasActive { selectedBandID = settings.bands.first?.id }
    }

    /// 回到出厂预设（自定义卡保留，可再点回来）
    func revertToBasePreset() {
        if let scene = profile.baseScene {
            apply(scene)
        } else {
            apply(profile.basePreset ?? .flat)
        }
    }

    // MARK: - 频段操作（全部自动写入自定义卡）

    func selectBand(_ id: UUID?) {
        guard selectedBandID != id else { return }
        selectedBandID = id
    }

    func band(_ id: UUID) -> Band? {
        settings.bands.first { $0.id == id }
    }

    func updateBand(_ id: UUID, _ body: (inout Band) -> Void) {
        guard let idx = settings.bands.firstIndex(where: { $0.id == id }) else { return }
        if settings.effectStrength < 0.01 { setEffectStrength(1) }
        var s = settings
        body(&s.bands[idx])
        var b = s.bands[idx]
        if !b.freq.isFinite { b.freq = 1_000 }
        if !b.gainDB.isFinite { b.gainDB = 0 }
        b.freq = min(max(b.freq, EQSettings.freqRange.lowerBound), EQSettings.freqRange.upperBound)
        b.gainDB = min(max(b.gainDB, EQSettings.gainRange.lowerBound), EQSettings.gainRange.upperBound)
        s.bands[idx] = b
        guard s.bands != settings.bands else { return }

        withBatchedPersist {
            commitTonalChange(s)
            settings = s
        }
    }

    func setBandGain(_ id: UUID, _ v: Float) { updateBand(id) { $0.gainDB = v } }
    func setBandFreq(_ id: UUID, _ v: Float) { updateBand(id) { $0.freq = v } }
    func setBandEnabled(_ id: UUID, _ on: Bool) { updateBand(id) { $0.enabled = on } }
    func resetBand(_ id: UUID) { updateBand(id) { $0.gainDB = 0 } }

    /// 一次性替换全部控制点（拖动整条曲线用）。
    /// 与 updateBand 走同一条提交路径：自动写入自定义卡、触发参数重发布。
    func setInstrument(_ kind: InstrumentKind, preset: Int? = nil, gainDB: Float? = nil) {
        mutateTonal { s in
            let old = s.instruments[kind]
            // 先固定原有顺序，再变更开关/预置；增益微调不抢占别人的锁。
            s.moduleOrder = s.activeModuleOrder
            s.instruments[kind] = InstrumentModule(preset: preset ?? old.preset, gainDB: gainDB ?? old.gainDB)
            s.updateModuleOrder(ToneModule(rawValue: kind.rawValue)!, reclaim: preset != nil && preset != old.preset)
        }
    }

    func setEffectStrength(_ value: Float) {
        mutateTonal { $0.effectStrength = min(max(value, 0), 2) }
    }

    func setBands(_ newBands: [Band]) {
        var s = settings
        s.bands = Array(newBands.prefix(EQSettings.maxBands)).map { b in
            var out = b
            if !out.freq.isFinite { out.freq = 1_000 }
            if !out.gainDB.isFinite { out.gainDB = 0 }
            out.freq = min(max(out.freq, EQSettings.freqRange.lowerBound), EQSettings.freqRange.upperBound)
            out.gainDB = min(max(out.gainDB, EQSettings.gainRange.lowerBound), EQSettings.gainRange.upperBound)
            return out
        }
        guard s.bands != settings.bands else { return }
        withBatchedPersist {
            commitTonalChange(s)
            settings = s
        }
    }

    @discardableResult
    func addBand(freq: Float, gainDB: Float) -> UUID? {
        guard settings.bands.count < EQSettings.maxBands else { return nil }
        let clampedFreq = min(max(freq, EQSettings.freqRange.lowerBound), EQSettings.freqRange.upperBound)
        let clampedGain = min(max(gainDB, EQSettings.gainRange.lowerBound), EQSettings.gainRange.upperBound)
        let band = Band(freq: clampedFreq, gainDB: clampedGain)

        var s = settings
        s.bands.append(band)
        withBatchedPersist {
            commitTonalChange(s)
            settings = s
        }
        selectedBandID = band.id
        return band.id
    }

    /// 在频点最稀疏的位置加一段，避免新节点叠在旧节点上
    func addBandAtSuggestedFreq() {
        addBand(freq: Self.suggestedFreq(existing: settings.bands.map(\.freq)), gainDB: 0)
    }

    func removeBand(_ id: UUID) {
        guard let idx = settings.bands.firstIndex(where: { $0.id == id }) else { return }
        var s = settings
        s.bands.remove(at: idx)
        withBatchedPersist {
            commitTonalChange(s)
            settings = s
        }
        if selectedBandID == id {
            selectedBandID = s.bands.isEmpty ? nil : s.bands[min(idx, s.bands.count - 1)].id
        }
    }

    // MARK: - 场景模块

    func setBassMode(_ mode: BassMode) {
        mutateTonal { s in
            s.moduleOrder = s.activeModuleOrder
            let changed = s.bass.mode != mode
            s.bass.mode = mode
            s.updateModuleOrder(.bass, reclaim: changed)
        }
    }

    func setBassCenter(_ hz: Float) {
        mutateTonal { s in
            s.moduleOrder = s.activeModuleOrder
            let changed = s.bass.centerHz != hz
            s.bass.centerHz = hz
            s.updateModuleOrder(.bass, reclaim: changed)
        }
    }

    func setBassStrength(_ strength: BassStrength) {
        mutateTonal { $0.bass.strength = strength }
    }

    func setClarity(_ value: Float) {
        mutateTonal { s in
            s.moduleOrder = s.activeModuleOrder
            s.clarityDB = min(max(value, -6), 6)
            s.updateModuleOrder(.clarity, reclaim: false)
        }
    }

    /// 把当前曲线采样到标准 10 个中心频率，之后只允许纵向调增益。
    func alignToStandardBands() {
        var s = settings
        s.bands = EQSettings.standardFrequencies.map { f in
            Band(freq: f, gainDB: settings.eqCurveDB(at: f))
        }
        s.bandLayout = .standard10
        withBatchedPersist {
            commitTonalChange(s)
            settings = s
        }
        selectedBandID = s.bands.first?.id
    }

    // MARK: - 全局参数（preamp / trim / 限幅不属于预设内容，不触发自定义复制）

    func setTrim(_ v: Float) { mutateGlobal { $0.trimDB = min(max(v, -12), 12) } }
    func setPreamp(_ v: Float) { mutateGlobal { $0.preampDB = min(max(v, -18), 18) } }
    func setFlag(_ key: WritableKeyPath<EQSettings, Bool>, _ value: Bool) {
        mutateGlobal { $0[keyPath: key] = value }
    }

    private func mutateGlobal(_ body: (inout EQSettings) -> Void) {
        var s = settings
        body(&s)
        guard s != settings else { return }
        settings = s
    }

    private func withBatchedPersist(_ body: () -> Void) {
        suspendPersist = true
        body()
        suspendPersist = false
        persistSettings()
    }

    /// 任何音色参数（曲线、低音模块、清晰度）被改动时同步写进常驻自定义卡：
    /// - 在预设上改 → 生成/覆盖卡片，并切到卡片
    /// - 在卡片上改 → 更新卡片
    private func commitTonalChange(_ s: EQSettings) {
        switch profile {
        case let .scene(scene):
            customSlot = makeCustomSlot(from: s, presetBase: nil, sceneBase: scene)
            profile = .custom(base: nil, scene: scene)
        case let .preset(p):
            customSlot = makeCustomSlot(from: s, presetBase: p, sceneBase: nil)
            profile = .custom(base: p, scene: nil)
        case let .custom(base, scene):
            customSlot = makeCustomSlot(from: s, presetBase: base, sceneBase: scene)
        }
    }

    private func makeCustomSlot(from s: EQSettings, presetBase: Preset?, sceneBase: ScenePreset?) -> CustomSlot {
        CustomSlot(bands: s.bands,
                   base: presetBase,
                   sceneBase: sceneBase,
                   bass: s.bass,
                   clarityDB: s.clarityDB,
                   effectStrength: s.effectStrength,
                   instruments: s.instruments,
                   moduleOrder: s.moduleOrder,
                   bandLayout: s.bandLayout)
    }

    private func mutateTonal(_ body: (inout EQSettings) -> Void) {
        var s = settings
        body(&s)
        guard s != settings else { return }
        withBatchedPersist {
            commitTonalChange(s)
            settings = s
        }
    }

    // MARK: - 引擎

    func restartEngine() {
        engine.stop()
        engine.start()
        refreshStatus()
    }

    func refreshStatus() {
        deviceName = currentDeviceName.isEmpty ? "—" : currentDeviceName
        latencyMs = engine.framesPerBuffer > 0 && engine.sampleRate > 0
            ? Double(engine.framesPerBuffer) / Double(engine.sampleRate) * 1000
            : 0
        sampleRateText = engine.sampleRate > 0 ? "\(Int(engine.sampleRate)) Hz" : "—"
        errorText = engine.lastError ?? storageError

        if engine.isRunning {
            statusLine = "运行中"
        } else if let e = engine.lastError {
            statusLine = "失败"
            errorText = e
        } else {
            statusLine = enabled ? "启动中" : "已旁通"
        }
        objectWillChange.send()
    }

    func pollMeters() -> MeterSnapshot {
        if meterDemoLevels { return MeterBallistics.demoSnapshot() }
        let now = ProcessInfo.processInfo.systemUptime
        // 面板关着时没人读数；隔了很久再打开，先丢掉那段时间累计的峰值，
        // 否则表头会把几分钟前的瞬态当成当前电平
        if lastMeterPoll > 0, now - lastMeterPoll > 1.0 {
            _ = engine.takeMeterRaw()
            meterBallistics.reset()
        }
        lastMeterPoll = now
        return meterBallistics.update(engine.takeMeterRaw(), now: now)
    }

    /// 离屏截图（--snapshot）时给电平表喂固定读数，便于检查排版
    var meterDemoLevels = false

    private let meterBallistics = MeterBallistics()
    private var lastMeterPoll: TimeInterval = 0

    var curveSampleRate: Float {
        engine.sampleRate > 0 ? engine.sampleRate : 48_000
    }

    // MARK: - 持久化

    private var stateKey: String {
        currentUID.isEmpty ? "state.v2.local" : "state.v2.\(currentUID)"
    }

    private var settingsKey: String {
        currentUID.isEmpty ? "settings.local" : "settings.\(currentUID)"
    }

    private var profileKey: String {
        currentUID.isEmpty ? "profile.local" : "profile.\(currentUID)"
    }

    private var customSlotKey: String {
        currentUID.isEmpty ? "customSlot.local" : "customSlot.\(currentUID)"
    }

    private func persistSettings() {
        guard !persistPaused, !suspendPersist, !currentUID.isEmpty,
              !currentDeviceName.isEmpty else { return }
        let state = PersistedState(settings: settings, profile: profile, customSlot: customSlot)
        do {
            try deviceProfiles.save(name: currentDeviceName, state: state, enabled: enabled)
            storageError = nil
        } catch {
            storageError = "设备 EQ 保存失败：\(error.localizedDescription)"
            errorText = storageError
            NSLog("%@", storageError!)
        }
    }

    /// 文件按名称匹配；只迁移本设备 UID 的旧存档，首次启动才允许迁移旧全局数据。
    func loadSettingsForCurrentDevice(allowGlobalMigration: Bool = false) {
        guard !currentUID.isEmpty, !currentDeviceName.isEmpty else { return }
        let defaults = UserDefaults.standard
        let migrateGlobal = allowGlobalMigration && !FileManager.default.fileExists(atPath: deviceProfiles.url.path)
        var saved: DeviceEQProfile?
        do {
            saved = try deviceProfiles.profile(named: currentDeviceName)
            storageError = nil
        } catch {
            storageError = "设备 EQ 读取失败：\(error.localizedDescription)"
            errorText = storageError
            NSLog("%@", storageError!)
        }
        var loaded: PersistedState?
        if let saved { loaded = saved.state }
        if loaded == nil, let data = defaults.data(forKey: stateKey) {
            loaded = try? JSONDecoder().decode(PersistedState.self, from: data)
        }
        if loaded == nil,
           let data = defaults.data(forKey: settingsKey)
                ?? (migrateGlobal ? defaults.data(forKey: "settings") : nil),
           let s = try? JSONDecoder().decode(EQSettings.self, from: data) {
            let p = (defaults.data(forKey: profileKey)
                ?? (migrateGlobal ? defaults.data(forKey: "profile") : nil))
                .flatMap { try? JSONDecoder().decode(ProfileRef.self, from: $0) }
            let c = defaults.data(forKey: customSlotKey)
                .flatMap { try? JSONDecoder().decode(CustomSlot.self, from: $0) }
            loaded = PersistedState(settings: s, profile: p ?? AppState.inferProfile(s), customSlot: c)
        }
        let hasLegacyState = loaded != nil
        if loaded == nil {
            var s = EQSettings()
            Preset.flat.apply(to: &s)
            loaded = PersistedState(settings: s, profile: .preset(.flat), customSlot: nil)
        }
        let resolved = AppState.resolve(settings: loaded!.settings,
                                        profile: loaded!.profile, slot: loaded!.customSlot)
        withBatchedPersist {
            settings = resolved.settings
            profile = resolved.profile
            customSlot = resolved.slot
            enabled = saved?.enabled ?? ((allowGlobalMigration && hasLegacyState) ? enabled : false)
        }
        selectedBandID = resolved.settings.bands.first?.id
    }

    /// 先保存旧设备，再更换名称和 UID，避免把 A 的参数写入 B 的文件条目。
    func switchOutputDevice(uid: String, name: String) {
        guard !uid.isEmpty, !name.isEmpty,
              uid != currentUID || name != currentDeviceName else { return }
        persistSettings()
        engine.stop()
        currentUID = uid
        currentDeviceName = name
        loadSettingsForCurrentDevice()
        if enabled { engine.start() }
        refreshStatus()
    }

    /// 启动/换设备时把 settings、profile、自定义卡三者对齐：
    /// 旧存档没有卡片时把当前曲线物化成卡片；profile 是预设但曲线已经不匹配时降级成自定义卡。
    private static func resolve(settings: EQSettings, profile: ProfileRef?, slot: CustomSlot?)
        -> (settings: EQSettings, profile: ProfileRef, slot: CustomSlot?) {
        var s = settings
        s.moduleOrder = s.activeModuleOrder
        let wasCustom = profile?.isCustom ?? false
        var p = profile ?? AppState.inferProfile(s)
        var c = slot

        // 旧版 4 段参数 EQ：如果曲线仍是某个旧预设的原样，直接升级成新版更强的预设。
        // 用户自己改过的曲线（profile 已是 custom）保持不动，迁移成自定义卡。
        if !wasCustom, let legacy = AppState.legacyPreset(for: s) {
            s.bands = legacy.bands
            p = .preset(legacy)
        }

        switch p {
        case let .scene(scene) where !AppState.matches(scene, s):
            p = .custom(base: nil, scene: scene)
        case let .preset(preset) where !AppState.matches(preset, s):
            p = .custom(base: preset, scene: nil)
        default:
            break
        }

        if case let .custom(base, scene) = p {
            // 卡只是 settings 的一份镜像；settings 的写入顺序在前，不可能比卡旧。
            // 两处不一致时以 settings 为准，顺便修复卡片并清掉超出上限的段。
            let bands = Array(s.bands.prefix(EQSettings.maxBands))
            c = CustomSlot(bands: bands,
                           base: base,
                           sceneBase: scene,
                           bass: s.bass,
                           clarityDB: s.clarityDB,
                   effectStrength: s.effectStrength,
                   instruments: s.instruments,
                   moduleOrder: s.moduleOrder,
                           bandLayout: s.bandLayout)
            if bands.count != s.bands.count { s.bands = bands }
        } else if let existing = c {
            // 非激活状态下仅做段数消毒
            if existing.bands.count > EQSettings.maxBands {
                var sanitized = existing
                sanitized.bands = Array(existing.bands.prefix(EQSettings.maxBands))
                c = sanitized
            }
        }
        return (s, p, c)
    }

    // MARK: - 推断 / 设备切换

    static func inferProfile(_ s: EQSettings) -> ProfileRef {
        for scene in ScenePreset.allCases where matches(scene, s) {
            return .scene(scene)
        }
        for p in Preset.allCases where matches(p, s) {
            return .preset(p)
        }

        // 非出厂值：分别找最接近的场景和经典预设，作为「回到预设」目标。
        let nearestScene = ScenePreset.allCases.min {
            sceneDistance($0, s) < sceneDistance($1, s)
        }
        let nearestPreset = Preset.allCases.min {
            distance($0, s.bands) < distance($1, s.bands)
        } ?? .flat
        if let nearestScene, sceneDistance(nearestScene, s) < distance(nearestPreset, s.bands) {
            return .custom(base: nil, scene: nearestScene)
        }
        return .custom(base: nearestPreset, scene: nil)
    }

    static func matches(_ preset: Preset, _ s: EQSettings) -> Bool {
        let pb = preset.bands
        guard s.instruments == InstrumentModules(), abs(s.effectStrength - 1) < 0.001,
              s.bass == BassSettings(), abs(s.clarityDB) < 0.01,
              s.bandLayout == .freeform,
              pb.count == s.bands.count else { return false }
        return zip(pb, s.bands).allSatisfy { (a, b) in
            a.enabled && b.enabled
                && abs(a.freq - b.freq) < 0.5
                && abs(a.gainDB - b.gainDB) < 0.05
        }
    }

    static func matches(_ scene: ScenePreset, _ s: EQSettings) -> Bool {
        let sb = scene.bands
        guard s.instruments == InstrumentModules(), abs(s.effectStrength - 1) < 0.001,
              s.bandLayout == .standard10,
              s.bass == scene.defaultBass,
              abs(s.clarityDB - scene.defaultClarityDB) < 0.05,
              sb.count == s.bands.count else { return false }
        return zip(sb, s.bands).allSatisfy { (a, b) in
            a.enabled && b.enabled
                && abs(a.freq - b.freq) < 0.5
                && abs(a.gainDB - b.gainDB) < 0.05
        }
    }

    /// 旧版 4 段（38 / 90 / 180 / 9k）是否仍等于某个旧预设的出厂值
    private static func legacyPreset(for s: EQSettings) -> Preset? {
        let b = s.bands
        guard b.count == 4 else { return nil }
        let freqs: [Float] = [38, 90, 180, 9_000]
        guard zip(b, freqs).allSatisfy({ (band, f) in abs(band.freq - f) < 0.5 && band.enabled }) else { return nil }
        let table: [(Preset, [Float])] = [
            (.flat, [0, 0, 0, 0]),
            (.bassBoost, [3, 6, 0, 0]),
            (.deepSub, [6, 5, 1, 0]),
            (.punch, [2, 4, 3, 1]),
            (.warm, [1, 2, 2.5, 0]),
            (.cinema, [5, 7, -2, 0]),
        ]
        for (p, gains) in table {
            if zip(b, gains).allSatisfy({ (band, g) in abs(band.gainDB - g) < 0.05 }) { return p }
        }
        return nil
    }

    private static func distance(_ p: Preset, _ bands: [Band]) -> Float {
        let pb = p.bands
        var d = Float(abs(pb.count - bands.count)) * 10
        for (a, b) in zip(pb, bands) {
            d += abs(a.gainDB - b.gainDB)
            d += abs(log(max(a.freq, 1)) - log(max(b.freq, 1))) * 2
        }
        return d
    }

    private static func sceneDistance(_ scene: ScenePreset, _ s: EQSettings) -> Float {
        var d = distance(.flat, s.bands)
        d += abs(s.clarityDB - scene.defaultClarityDB) * 2
        if s.bass.mode != scene.defaultBass.mode { d += 6 }
        d += abs(s.bass.strength.peakDB - scene.defaultBass.strength.peakDB)
        d += abs(log(max(s.bass.centerHz, 1)) - log(max(scene.defaultBass.centerHz, 1))) * 3
        return d
    }

    private static func suggestedFreq(existing: [Float]) -> Float {
        let edges = [EQSettings.freqRange.lowerBound] + existing.sorted() + [EQSettings.freqRange.upperBound]
        var bestGap: Float = -1
        var bestMid: Float = 1_000
        for i in 1..<edges.count {
            let gap = log(edges[i]) - log(edges[i - 1])
            if gap > bestGap {
                bestGap = gap
                bestMid = exp((log(edges[i]) + log(edges[i - 1])) / 2)
            }
        }
        return min(max(bestMid, EQSettings.freqRange.lowerBound), EQSettings.freqRange.upperBound)
    }

    private func installDeviceListener() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                let device = TapEngine.defaultOutputDevice()
                self.switchOutputDevice(uid: TapEngine.uid(of: device), name: TapEngine.name(of: device))
            }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }
}
