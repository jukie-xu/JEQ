import Foundation
import SwiftUI
import AppKit

/// 离线 DSP 校验 + 实时链路校验。全部输出数值，不靠"听起来像"。
enum SelfTest {

    static let sr: Float = 48_000
    static func runLockTest() -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print("\(ok ? "✓" : "✗") \(label)")
            if !ok { failures += 1 }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JEQ-lock-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DeviceProfileStore(url: directory.appendingPathComponent("devices.json"))
        let app = AppState(deviceProfiles: store, initialDevice: ("lock-test-\(UUID())", "锁定测试设备"), observeDevices: false)
        app.apply(Preset.flat)
        app.setInstrument(.strings, preset: 1, gainDB: 3)
        let reference = app.settings.effectiveCurveDB(at: 250)
        app.setInstrument(.vocals, preset: 1, gainDB: 6)
        check(app.settings.moduleOwner(at: 250) == .strings,
              "先开启的弦乐优先拥有 250 Hz")
        check(abs(app.settings.effectiveCurveDB(at: 250) - reference) < 0.001,
              "后开启人声不改变弦乐锁定的频段")
        let positive = app.settings
        app.setInstrument(.vocals, gainDB: -6)
        check(abs(app.settings.effectiveCurveDB(at: 250) - reference) < 0.001,
              "人声从 +6 到 -6 dB 不穿透弦乐锁")
        check(app.settings.moduleLockText(.vocals).contains("弦乐模块"), "界面明确显示占用模块")
        app.setInstrument(.strings, preset: 0)
        check(app.settings.moduleOwner(at: 250) == .vocals
              && app.settings.effectiveCurveDB(at: 250) < -5.9,
              "关闭弦乐后释放频段，由已开启人声立即接管")
        app.setInstrument(.strings, preset: 1, gainDB: 3)
        check(app.settings.moduleOwner(at: 250) == .vocals, "重新开启弦乐不会抢回人声的锁")
        app.setInstrument(.vocals, preset: 2)
        check(app.settings.moduleOwner(at: 250) == .strings,
              "切换人声预置释放旧频段，并重新申请新范围")
        let restored = AppState(deviceProfiles: DeviceProfileStore(url: store.url),
                                initialDevice: ("different-uid-\(UUID())", "锁定测试设备"), observeDevices: false)
        check(restored.settings.moduleOrder == app.settings.moduleOrder
              && restored.settings.moduleOwner(at: 250) == .strings,
              "设备名称存档和重启恢复后保留锁定优先级")
        app.apply(Preset.flat)
        app.setBassMode(.natural)
        app.setInstrument(.drums, preset: 1, gainDB: -6)
        let bassReference = app.settings.effectiveCurveDB(at: 70)
        app.setInstrument(.drums, gainDB: 6)
        check(abs(app.settings.effectiveCurveDB(at: 70) - bassReference) < 0.001,
              "低音先开启时鼓点不会覆盖其负责频段")
        app.setBassMode(.off)
        check(app.settings.moduleOwner(at: 70) == .drums && app.settings.effectiveCurveDB(at: 70) > 5.9,
              "关闭低音后鼓点接管对应频段")
        app.setBassMode(.natural)
        let drumReference = app.settings.effectiveCurveDB(at: 70)
        app.setBassStrength(.high)
        check(abs(app.settings.effectiveCurveDB(at: 70) - drumReference) < 0.001,
              "鼓点先锁定后，低音强度变化不会覆盖鼓点")
        // DSP 拟合允许小误差；除去全局预衰减后检查实际音频中的锁定频段。
        func measured(_ s: EQSettings) -> Float {
            let f: Float = 250
            let input = sine(f, amp: 0.001, n: 48_000, sr: sr)
            let output = process(input, settings: s, sr: sr)
            let a = input.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 24_000, 24_000, f, sr) }
            let b = output.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 24_000, 24_000, f, sr) }
            return Float(20 * log10(b / a)) - s.effectivePreampDB
        }
        var negative = positive
        negative.instruments.vocals.gainDB = -6
        let delta = abs(measured(positive) - measured(negative))
        check(delta < 0.75, String(format: "实际音频锁定频段差异 %.3f dB（自动预衰减归一后）", delta))
        // 连续采样检查所有权交界无硬跳变。
        var previous = negative.effectiveCurveDB(at: 20)
        var largest: Float = 0
        for i in 1...10_000 {
            let f = 20 * pow(Float(1000), Float(i) / 10_000)
            let now = negative.effectiveCurveDB(at: f)
            largest = max(largest, abs(now - previous)); previous = now
        }
        check(largest < 0.2, String(format: "所有权交界平滑，密集采样最大相邻变化 %.3f dB", largest))
        print("频段锁定测试：\(failures) 个失败")
        return failures == 0
    }

    static func runInstrumentTest() -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "✓" : "✗") \(name)")
            if !ok { failures += 1 }
        }
        for kind in InstrumentKind.allCases {
            for index in 1...3 {
                let preset = kind.presets[index - 1]
                for gain: Float in [-6, 6] {
                    var s = EQSettings()
                    Preset.flat.apply(to: &s)
                    s.instruments[kind] = InstrumentModule(preset: index, gainDB: gain)
                    s.limiter = false
                    let target = s.effectiveCurveDB(at: preset.centerHz) + s.effectivePreampDB
                    let input = sine(preset.centerHz, amp: 0.001, n: 48_000, sr: sr)
                    let output = process(input, settings: s, sr: sr)
                    let a = input.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 24_000, 24_000, preset.centerHz, sr) }
                    let b = output.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 24_000, 24_000, preset.centerHz, sr) }
                    let actual = Float(20 * log10(b / a))
                    check(abs(actual - target) < 1,
                          "\(kind.title)/\(preset.title) \(gain) dB：音频处理与目标相符")
                    for band in s.bands {
                        let displayed = s.displayedGainDB(for: band)
                        check(abs(s.bandGainDB(forDisplayedGain: displayed, at: band.freq) - band.gainDB) < 0.001,
                              "\(kind.rawValue) \(band.freq) Hz 节点反算不重复叠加")
                    }
                    s.instruments[kind].preset = 0
                    check(abs(s.effectiveCurveDB(at: preset.centerHz)) < 0.001, "关闭该模块立即移除频响贡献")
                }
            }
        }
        var stacked = EQSettings()
        ScenePreset.heavyBass.apply(to: &stacked)
        for kind in InstrumentKind.allCases {
            stacked.instruments[kind] = InstrumentModule(preset: 1, gainDB: 6)
        }
        stacked.effectStrength = 2
        let range = stacked.displayDBRange
        check((0...256).allSatisfy {
            range.contains(stacked.effectiveCurveDB(at: 20 * pow(Float(1000), Float($0) / 256)))
        }, "多模块叠加及 200% 强度时绘图范围覆盖整条曲线")
        let data = try! JSONEncoder().encode(stacked)
        check((try! JSONDecoder().decode(EQSettings.self, from: data)) == stacked,
              "四个模块、预置和增益完整持久化")
        let oldData = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        var legacy = oldData
        legacy.removeValue(forKey: "instruments")
        let decoded = try! JSONDecoder().decode(EQSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(decoded.instruments == InstrumentModules(), "旧配置缺少新模块时默认全部关闭")
        let malformed = try! JSONDecoder().decode(InstrumentModule.self,
                from: Data("{\"preset\":99,\"gainDB\":100}".utf8))
        check(malformed.preset == 3 && malformed.gainDB == 6, "文件中的越界模块参数被限制到合法范围")
        Preset.flat.apply(to: &stacked)
        check(stacked.instruments == InstrumentModules(), "选择出厂预设清除模块叠加，可回到原始音色")
        print("乐器模块测试：\(failures) 个失败")
        return failures == 0
    }

    static func runDeviceTest() -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "✓" : "✗") \(name)")
            if !ok { failures += 1 }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("JEQ-device-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("device-profiles.json")
        let store = DeviceProfileStore(url: url)
        let uidA = "test-A-\(UUID())"
        let uidB = "test-B-\(UUID())"
        let app = AppState(deviceProfiles: store, initialDevice: (uidA, "测试耳机 A"), observeDevices: false)
        app.apply(.speech)
        app.setEffectStrength(0.65)
        app.setInstrument(.vocals, preset: 2, gainDB: -2.5)
        app.setInstrument(.piano, preset: 3, gainDB: 4)
        let aSettings = app.settings
        let aProfile = app.profile
        let aSlot = app.customSlot
        app.switchOutputDevice(uid: uidB, name: "测试音箱 B")
        check(app.profile == .preset(.flat) && app.customSlot == nil && !app.enabled,
              "首次连接新设备使用独立直通配置，不继承 A")
        app.apply(Preset.cinema)
        let bSettings = app.settings
        app.switchOutputDevice(uid: uidA, name: "测试耳机 A")
        check(app.settings == aSettings && app.profile == aProfile && app.customSlot == aSlot,
              "A → B → A 恢复完整参数、选择、强度和自定义卡")
        app.switchOutputDevice(uid: "new-UID-\(UUID())", name: "测试音箱 B")
        check(app.settings == bSettings && app.profile == .preset(.cinema) && app.customSlot == nil,
              "同名设备更换 UID 后恢复 B，且不携带 A 的自定义卡")
        let relaunched = AppState(deviceProfiles: DeviceProfileStore(url: url),
                                 initialDevice: (uidA, "测试耳机 A"), observeDevices: false)
        check(relaunched.settings == aSettings && relaunched.profile == aProfile && relaunched.customSlot == aSlot,
              "重新创建应用状态，从文件恢复设备 A")
        do {
            let fresh = DeviceProfileStore(url: url)
            check(try fresh.profile(named: "测试耳机 A")?.state.settings == aSettings,
                  "从新文件实例读回 A，确认参数实际落盘")
            check(try fresh.profile(named: "测试音箱 B")?.state.settings == bSettings,
                  "A 与 B 在同一 JSON 内分别保存，互不覆盖")
            let state = PersistedState(settings: aSettings, profile: aProfile, customSlot: aSlot)
            try fresh.save(name: "斜线/蓝牙:耳机 🎧", state: state, enabled: true)
            check(try fresh.profile(named: "斜线/蓝牙:耳机 🎧")?.enabled == true,
                  "设备名含路径字符和中文时安全存储，启用状态独立持久化")
            try Data("{broken".utf8).write(to: url)
            do {
                try fresh.save(name: "C", state: state, enabled: false)
                check(false, "损坏文件禁止覆盖")
            } catch {
                check(try Data(contentsOf: url) == Data("{broken".utf8), "损坏文件报错并保留原始内容")
            }
        } catch {
            check(false, "文件存储测试异常：\(error)")
        }
        // 旧 UID 配置迁移；只操作随机键，测试结束删除。
        let legacyUID = "migration-test-\(UUID())"
        let legacyKey = "state.v2.\(legacyUID)"
        let legacyURL = dir.appendingPathComponent("legacy.json")
        let legacy = PersistedState(settings: bSettings, profile: .preset(.cinema), customSlot: nil)
        UserDefaults.standard.set(try! JSONEncoder().encode(legacy), forKey: legacyKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }
        let migrated = AppState(deviceProfiles: DeviceProfileStore(url: legacyURL),
                                initialDevice: (legacyUID, "旧版耳机"), observeDevices: false)
        check(migrated.settings == bSettings && migrated.profile == .preset(.cinema),
              "旧 UID 存档迁移时保留 EQ 和当前选择")
        check((try? DeviceProfileStore(url: legacyURL).profile(named: "旧版耳机")) != nil,
              "旧存档自动写入名称配置文件")
        print("设备存储测试：\(failures) 个失败")
        return failures == 0
    }


    // MARK: - 工具

    static func goertzelAmp(_ x: UnsafePointer<Float>, _ n: Int, _ f: Float, _ sr: Float) -> Double {
        guard n > 8 else { return 0 }
        let k = Int(0.5 + Double(n) * Double(f) / Double(sr))
        let w = 2 * Double.pi * Double(k) / Double(n)
        let c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<n {
            let s0 = Double(x[i]) + c * s1 - s2
            s2 = s1; s1 = s0
        }
        let re = s1 - s2 * cos(w), im = s2 * sin(w)
        return (re * re + im * im).squareRoot() / (Double(n) / 2)
    }

    /// 把一段信号过一遍完整的链路（与音频线程同一份滤波器组）
    static func process(_ input: [Float], settings: EQSettings, sr: Float) -> [Float] {
        let coeffs = FilterBank.coeffs(for: settings, sampleRate: sr)
        var out = [Float](repeating: 0, count: input.count)
        let st = BiquadState(capacity: ParamStore.maxBands)
        let pre = pow(10, settings.effectivePreampDB / 20)
        let make = pow(10, settings.trimDB / 20)

        func run(_ base: UnsafePointer<BiquadCoeff>?, _ count: Int) {
            for i in 0..<input.count {
                var y = input[i] * pre
                if let base, count > 0 {
                    y = st.process(y, coeffs: base, count: count)
                }
                y *= make
                if settings.limiter {
                    y = DSPLimits.softLimit(y)
                }
                out[i] = y
            }
        }

        coeffs.withUnsafeBufferPointer { buf in
            run(buf.baseAddress, buf.count)
        }
        return out
    }

    static func sine(_ f: Float, amp: Float, n: Int, sr: Float) -> [Float] {
        (0..<n).map { i in amp * sin(2 * .pi * f * Float(i) / sr) }
    }

    static func describe(_ bands: [Band]) -> String {
        bands.map { b in
            String(format: "%@ %.0fHz %+.1fdB", b.enabled ? "" : "(off)", b.freq, b.gainDB)
        }.joined(separator: " / ")
    }

    // MARK: - 1. 频响：理论 vs 实测

    static func runDSP() {
        print("=== JEQ DSP 校验 (sr=\(Int(sr))) ===\n")

        let freqs: [Float] = [25, 38, 60, 90, 120, 180, 1_000, 9_000, 15_000]

        for p in Preset.allCases {
            var s = EQSettings()
            p.apply(to: &s)
            s.autoPreamp = false      // 隔离频响，不让 preamp 干扰测量
            s.preampDB = 0
            s.trimDB = 0
            s.limiter = false

            print("— \(p.title)：\(describe(s.bands))")
            print("   freq      理论dB    实测dB    偏差")
            for f in freqs {
                let theory = s.responseDB(at: f, sampleRate: sr)

                // 用稳态正弦测实际增益
                let n = 48_000
                let x = sine(f, amp: 0.25, n: n, sr: sr)
                let y = process(x, settings: s, sr: sr)
                let seg = 12_000
                let aIn = x.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 12_000, seg, f, sr) }
                let aOut = y.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 12_000, seg, f, sr) }
                let measured = 20 * log10(max(aOut / max(aIn, 1e-9), 1e-9))
                print(String(format: "  %6.0f Hz  %+7.2f  %+8.2f  %+6.2f", f, theory, measured, measured - Double(theory)))
            }
            print("")
        }

        // 削波保护校验
        print("— 削波保护：deepSub + 自动 preamp + 限幅")
        var hot = EQSettings()
        Preset.deepSub.apply(to: &hot)
        let loud = sine(36, amp: 0.95, n: 48_000, sr: sr)
        let processed = process(loud, settings: hot, sr: sr)
        let peak = processed.map { abs($0) }.max() ?? 0
        print(String(format: "  输出峰值 = %.4f  (要求 < 1.0，且 preamp = %+.1f dB)", peak, hot.effectivePreampDB))
        print(peak < 1.0 ? "  ✓ 未削波" : "  ✗ 削波")
    }

    // MARK: - 2. 实时链路：tap 进 → DSP → 设备出

    static func runLiveProof() {
        print("=== JEQ 实时链路校验 ===\n")
        let state = AppState.shared
        state.persistPaused = true   // 测试参数不落盘，别覆盖用户配置

        let wanted = CommandLine.arguments.last ?? "deepSub"
        let preset = Preset.allCases.first { $0.rawValue == wanted } ?? .deepSub
        var s = EQSettings()
        preset.apply(to: &s)
        if CommandLine.arguments.contains("--silent") { s.trimDB = -60 }
        state.settings = s
        print("▸ 预设 = \(preset.rawValue)  silent=\(CommandLine.arguments.contains("--silent"))")

        state.engine.capture.reset()
        state.engine.capture.active = true
        state.engine.start()

        guard state.engine.isRunning else {
            print("✗ 引擎未启动：\(state.engine.lastError ?? "unknown")")
            return
        }
        print("▸ 引擎已启动  device=\(state.engine.outputDeviceName)  sr=\(Int(state.engine.sampleRate))  frames=\(state.engine.framesPerBuffer)")

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/tmp/tone.wav"]
        try? player.run()
        Thread.sleep(forTimeInterval: 2.6)
        if player.isRunning { player.terminate() }
        player.waitUntilExit()

        state.engine.capture.active = false
        state.engine.stop()

        let n = state.engine.capture.count
        print("▸ 采集帧数 = \(n)")
        guard n > 24_000 else { print("✗ 采集不足"); return }

        let inP = state.engine.capture.inBuf
        let outP = state.engine.capture.outBuf

        // 只比"形状"：输出/输入在同一频点的比值差，可抵消 preamp 与音量补偿这两个常数
        // 取末尾 1 秒：afplay 启动有随机延迟，固定窗口会踩到淡入段
        let win = 48_000
        let start = n - win - 2_000
        guard start > 0 else { print("✗ 窗口不足"); return }
        // 打印绝对幅度，便于判断输入是否与预设无关（应当无关）
        let in60 = goertzelAmp(inP + start, min(win, n - start), 60, sr)
        let in1k = goertzelAmp(inP + start, min(win, n - start), 1_000, sr)
        let out60 = goertzelAmp(outP + start, min(win, n - start), 60, sr)
        let out1k = goertzelAmp(outP + start, min(win, n - start), 1_000, sr)
        print(String(format: "▸ 幅度 in: 60Hz=%.5f 1kHz=%.5f | out: 60Hz=%.5f 1kHz=%.5f", in60, in1k, out60, out1k))

        func relDB(_ f: Float) -> Double {
            let aIn = goertzelAmp(inP + start, min(win, n - start), f, sr)
            let aOut = goertzelAmp(outP + start, min(win, n - start), f, sr)
            return 20 * log10(max(aOut / max(aIn, 1e-9), 1e-9))
        }

        let r60 = relDB(60), r1k = relDB(1_000)
        let theory = s.responseDB(at: 60, sampleRate: sr) - s.responseDB(at: 1_000, sampleRate: sr)
        print(String(format: "▸ relDB: 60Hz=%+.2f  1kHz=%+.2f  -> 差 %+.2f dB", r60, r1k, r60 - r1k))
        print(String(format: "▸ 60Hz 相对 1kHz 的增益：实测 %+.2f dB / 理论 %+.2f dB", r60 - r1k, theory))
        print(String(format: "▸ preamp=%+.1f dB  trim=%+.1f dB", s.effectivePreampDB, s.trimDB))
        let verdict = abs((r60 - r1k) - Double(theory)) < 1.2
        print(verdict ? "✓ 实时链路与离线模型一致，低音确实被抬起来了" : "✗ 实时链路与模型不一致，需要排查")

        // 落盘供外部 FFT 复核
        let tmp = FileManager.default.temporaryDirectory
        let inURL = tmp.appendingPathComponent("jeq_live_in.raw")
        let outURL = tmp.appendingPathComponent("jeq_live_out.raw")
        try? Data(bytes: inP, count: n * 4).write(to: inURL)
        try? Data(bytes: outP, count: n * 4).write(to: outURL)
        print("▸ 已写出 \(inURL.path) 与 \(outURL.path)")
    }

    // MARK: - 4. 整条曲线拖动（纯数学部分）

    /// 返回 true 表示全部通过，供 main 决定退出码。
    static func runCurveTest() -> Bool {
        print("=== JEQ 整条曲线拖动校验 ===\n")
        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            if ok {
                print("  ✓ \(label)")
            } else {
                failures += 1
                print("  ✗ \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
            }
        }
        func sameShape(_ a: [Band], _ b: [Band]) -> Bool {
            guard a.count == b.count else { return false }
            guard a.count > 1 else { return true }
            let d0 = a[0].gainDB - b[0].gainDB
            let r0 = a[0].freq / b[0].freq
            return zip(a, b).allSatisfy { x, y in
                abs((x.gainDB - y.gainDB) - d0) < 1e-4
                    && abs((x.freq / y.freq) - r0) < 1e-4
            }
        }

        // 含独立音效时，节点坐标与拖动写回必须互为逆运算。
        for mode in BassMode.allCases {
            for strength in BassStrength.allCases {
                var combined = EQSettings()
                ScenePreset.music.apply(to: &combined)
                combined.bass = BassSettings(mode: mode, centerHz: 80, strength: strength)
                combined.clarityDB = 3
                for i in combined.bands.indices {
                    let b = combined.bands[i]
                    let target = combined.displayedGainDB(for: b) - 2
                    combined.bands[i].gainDB = combined.bandGainDB(forDisplayedGain: target, at: b.freq)
                    check(abs(combined.effectiveCurveDB(at: b.freq) - target) < 0.001,
                          "\(mode.rawValue)/\(strength.rawValue) \(b.freq) Hz 节点拖动更新最终增益")
                }
                let original = combined
                combined.bands = CurveShift.apply(original.bands, deltaDB: 2, ratio: 1)
                check(zip(original.bands, combined.bands).allSatisfy {
                    $0.freq == $1.freq && abs($1.gainDB - $0.gainDB - 2) < 0.001
                }, "10 段整体拖动更新全部数据并锁定频率")
                let f: Float = 125
                combined.autoPreamp = false
                combined.limiter = false
                let input = sine(f, amp: 0.01, n: 48_000, sr: sr)
                let output = process(input, settings: combined, sr: sr)
                let a = input.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 24_000, 24_000, f, sr) }
                let b = output.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 24_000, 24_000, f, sr) }
                let measured = Float(20 * log10(b / a))
                check(abs(measured - combined.effectiveCurveDB(at: f)) < 1,
                      "\(mode.rawValue)/\(strength.rawValue) 实际音频增益跟随节点",
                      String(format: "target %.2f measured %.2f", combined.effectiveCurveDB(at: f), measured))
            }
        }

        // 直接驱动原生画布鼠标事件，覆盖标准 10 段曾被布局判断拦截的路径。
        let uiState = AppState.shared
        uiState.persistPaused = true
        var uiSettings = EQSettings()
        uiSettings.bandLayout = .standard10
        uiSettings.bands = EQSettings.standardFrequencies.map { Band(freq: $0, gainDB: 0) }
        uiSettings.bands[0].gainDB = 4
        uiSettings.bands[9].gainDB = -4
        uiState.settings = uiSettings
        let canvas = CurveCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 210))
        canvas.state = uiState
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                               modifierFlags: [], timestamp: 0, windowNumber: 0,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, 310, 105))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 310, 157.5))
        canvas.mouseUp(with: mouse(.leftMouseUp, 310, 157.5))
        check(abs(uiState.settings.effectStrength - 1.5) < 0.001,
              "原生拖动曲线：上拖加强至 150%")
        check(abs(uiState.settings.effectiveCurveDB(at: 31.5) - 6) < 0.001
              && abs(uiState.settings.effectiveCurveDB(at: 16_000) + 6) < 0.001,
              "整体加强同时扩大提升与衰减，改变频段比例")
        check(zip(uiState.settings.bands, uiSettings.bands).allSatisfy { $0.freq == $1.freq },
              "标准频率保持不变")
        uiSettings.bass = BassSettings(mode: .natural, centerHz: 80, strength: .high)
        uiSettings.effectStrength = 1.5
        uiState.settings = uiSettings
        let band = uiSettings.bands[2]
        let px = CGFloat(log(band.freq / 20) / log(Float(1000))) * 600
        let py = CGFloat((uiSettings.displayedGainDB(for: band) + 18) / 36) * 210
        canvas.mouseDown(with: mouse(.leftMouseDown, px, py))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, px, py - 17.5))
        canvas.mouseUp(with: mouse(.leftMouseUp, px, py - 17.5))
        check(abs(uiState.settings.bands[2].gainDB + 2) < 0.11,
              "150% 强度下圆点拖动正确反算频段增益")

        var strong = EQSettings()
        ScenePreset.heavyBass.apply(to: &strong)
        strong.clarityDB = 2
        func measuredContrast(_ settings: EQSettings) -> Float {
            func measured(_ freq: Float) -> Float {
                let input = sine(freq, amp: 0.001, n: 48_000, sr: sr)
                let output = process(input, settings: settings, sr: sr)
                let a = input.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 24_000, 24_000, freq, sr) }
                let b = output.withUnsafeBufferPointer { goertzelAmp($0.baseAddress! + 24_000, 24_000, freq, sr) }
                return Float(20 * log10(b / a))
            }
            return measured(63) - measured(1_000)
        }
        let originalContrast = measuredContrast(strong)
        strong.effectStrength = 0.5
        let weakContrast = measuredContrast(strong)
        strong.effectStrength = 1.5
        let strongContrast = measuredContrast(strong)
        print(String(format: "  实测低频/中频差：50%% %.2f / 100%% %.2f / 150%% %.2f dB", weakContrast, originalContrast, strongContrast))
        check(weakContrast < originalContrast - 2 && strongContrast > originalContrast + 2,
              "自动预衰减开启时，真实音频低频/中频比例仍随强度改变",
              String(format: "50%% %.2f / 100%% %.2f / 150%% %.2f dB", weakContrast, originalContrast, strongContrast))
        strong.effectStrength = 0
        check(abs(measuredContrast(strong)) < 0.01 && strong.maxBoost == 0,
              "0% 强度恢复平直音效")
        let saved = try! JSONEncoder().encode(strong)
        check((try! JSONDecoder().decode(EQSettings.self, from: saved)).effectStrength == 0,
              "强度可持久化，包括 0%")
        strong.effectStrength = 1
        check(abs(measuredContrast(strong) - originalContrast) < 0.01,
              "从 0% 恢复 100% 不丢失原始曲线")

        // 打击感最大增益 +10 dB，还有 8 dB 余量，适合测“正常平移”
        var s = EQSettings()
        Preset.punch.apply(to: &s)
        let base = s.bands

        let up = CurveShift.apply(base, deltaDB: 3.7, ratio: 1)
        check(zip(base, up).allSatisfy { abs(($0.gainDB + 3.7) - $1.gainDB) < 1e-4 },
              "增益整体 +3.7 dB")
        check(zip(base, up).allSatisfy { $0.freq == $1.freq }, "增益平移不改频率")
        check(zip(base, up).allSatisfy { $0.id == $1.id }, "节点 ID 保留")
        check(sameShape(up, base), "增益平移后曲线形状不变")

        var shifted = s
        shifted.bands = up
        for f: Float in [40, 90, 300, 2_000, 8_000] {
            let diff = shifted.eqCurveDB(at: f) - s.eqCurveDB(at: f)
            check(abs(diff - 3.7) < 0.01, "曲线在 \(Int(f)) Hz 整体抬升 3.7 dB",
                  String(format: "实测 %+.3f", diff))
        }

        let clipped = CurveShift.apply(base, deltaDB: 10, ratio: 1)
        let maxGain = clipped.map(\.gainDB).max() ?? 0
        let actualDelta = clipped[0].gainDB - base[0].gainDB
        check(abs(maxGain - 18) < 1e-4, "增益越界时整体停在 +18 dB",
              String(format: "max=%.2f", maxGain))
        check(abs(actualDelta - 8) < 1e-4, "越界时每点仍用同一偏移（+8 dB，曲线不被压扁）",
              String(format: "delta=%.2f", actualDelta))
        check(sameShape(clipped, base), "越界后仍保持形状")

        // 低音增强频率跨度最大（25 Hz–9.02 kHz），用来测移频边界
        var sb = EQSettings()
        Preset.bassBoost.apply(to: &sb)
        let fbase = sb.bands

        let wide = CurveShift.apply(fbase, deltaDB: 0, ratio: 2)
        check(zip(fbase, wide).allSatisfy { abs($1.freq - $0.freq * 2) < 0.01 }, "频率整体 ×2")
        check(zip(fbase, wide).allSatisfy { $0.gainDB == $1.gainDB }, "移频不改增益")
        check(sameShape(wide, fbase), "移频后曲线形状不变")

        let stretched = CurveShift.apply(fbase, deltaDB: 0, ratio: 10)
        let maxF = stretched.map(\.freq).max() ?? 0
        let expectedRatio: Float = 20_000 / 9_020
        let actualRatio = stretched[0].freq / fbase[0].freq
        check(abs(maxF - 20_000) < 1e-3, "频率越界时整体停在 20 kHz",
              String(format: "max=%.1f", maxF))
        check(abs(actualRatio - expectedRatio) < 1e-3,
              String(format: "所有点共用同一比例 ×%.3f", expectedRatio),
              String(format: "实测 ×%.4f", actualRatio))

        let limits = CurveShift.allowedRatio(fbase)
        check(abs(limits.lowerBound - 0.8) < 1e-4
              && abs(limits.upperBound - expectedRatio) < 1e-3,
              "移频边界由最外侧节点决定",
              String(format: "%.3f…%.3f", limits.lowerBound, limits.upperBound))

        let same = CurveShift.apply(base, deltaDB: 0, ratio: 1)
        check(same == base, "零偏移不改动控制点")
        check(CurveShift.apply([], deltaDB: 5, ratio: 2).isEmpty, "空曲线安全返回")

        print(failures == 0 ? "\n✓ 全部通过（\(failures) 个失败）" : "\n✗ \(failures) 项失败")
        return failures == 0
    }

    // MARK: - 4b. 场景 / 低音模块 / 固定余量

    static func runModeTest() -> Bool {
        print("=== JEQ 场景模式与低音模块校验 ===\n")
        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            if ok {
                print("  ✓ \(label)")
            } else {
                failures += 1
                print("  ✗ \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
            }
        }

        func peakFrequency(_ s: EQSettings) -> Float {
            var bestF: Float = 20
            var bestG = -Float.greatestFiniteMagnitude
            let n = 2_048
            for i in 0...n {
                let t = Float(i) / Float(n)
                let f = EQSettings.freqRange.lowerBound
                    * pow(EQSettings.freqRange.upperBound / EQSettings.freqRange.lowerBound, t)
                let g = s.effectiveCurveDB(at: f)
                if g > bestG { bestG = g; bestF = f }
            }
            return bestF
        }

        for scene in ScenePreset.allCases {
            var s = EQSettings()
            scene.apply(to: &s)
            let exact = zip(s.bands, EQSettings.standardFrequencies).allSatisfy {
                abs($0.freq - $1) < 0.01 && $0.enabled
            }
            check(exact && s.bands.count == 10,
                  "\(scene.title)：固定为标准 10 段",
                  "\(s.bands.count) 点 / \(s.bandLayout.title)")
            check(s.bass == scene.defaultBass && abs(s.clarityDB - scene.defaultClarityDB) < 1e-5,
                  "\(scene.title)：低音与清晰度模块随场景正确载入")
        }

        let natural = BassSettings(mode: .natural, centerHz: 80, strength: .high)
        let pure = BassSettings(mode: .pure, centerHz: 80, strength: .high)
        let sub = BassSettings(mode: .subwoofer, centerHz: 60, strength: .high)
        check(natural.curveDB(at: 80) > natural.curveDB(at: 20) + 5,
              "自然低音在选定中心形成宽峰")
        check(pure.curveDB(at: 80) > pure.curveDB(at: 250),
              "纯低音+保留中心低频、压低中低频拖尾")
        check(sub.curveDB(at: 39) > sub.curveDB(at: 120),
              "超低音主要提升 20–80 Hz 下潜")
        check(BassSettings().curveDB(at: 60) == 0,
              "低音模块在关闭状态下明确清零")

        // 全量程正弦 + 固定线性余量。关闭软限幅，直接验证预衰减足以避免削波。
        var safeFailures: [String] = []
        for scene in ScenePreset.allCases {
            var s = EQSettings()
            scene.apply(to: &s)
            s.limiter = false
            let hotF = peakFrequency(s)
            let out = process(sine(hotF, amp: 0.99, n: 48_000, sr: sr), settings: s, sr: sr)
            let settle = 12_000
            let peak = out[settle...].map { abs($0) }.max() ?? 0
            if peak > 0.995 {
                safeFailures.append(String(format: "%@ %.3f", scene.title, peak))
            }
        }
        for preset in Preset.allCases {
            var s = EQSettings()
            preset.apply(to: &s)
            s.limiter = false
            let hotF = peakFrequency(s)
            let out = process(sine(hotF, amp: 0.99, n: 48_000, sr: sr), settings: s, sr: sr)
            let settle = 12_000
            let peak = out[settle...].map { abs($0) }.max() ?? 0
            if peak > 0.995 {
                safeFailures.append(String(format: "%@ %.3f", preset.title, peak))
            }
        }
        check(safeFailures.isEmpty, "所有场景和经典预设在满量程输入下不削波",
              safeFailures.joined(separator: ", "))

        var staticCheck = EQSettings()
        ScenePreset.heavyBass.apply(to: &staticCheck)
        let firstHeadroom = staticCheck.staticHeadroomDB
        check(abs(staticCheck.staticHeadroomDB - firstHeadroom) < 1e-6,
              "固定余量不随播放内容变化")
        check(firstHeadroom <= -staticCheck.maxBoost,
              "固定余量至少覆盖整条曲线的最大正增益",
              String(format: "headroom %.2f / peak %.2f", firstHeadroom, staticCheck.maxBoost))

        let slot = CustomSlot(bands: staticCheck.bands,
                              base: nil,
                              sceneBase: .heavyBass,
                              bass: staticCheck.bass,
                              clarityDB: staticCheck.clarityDB,
                              bandLayout: staticCheck.bandLayout)
        let persisted = PersistedState(settings: staticCheck, profile: .scene(.heavyBass), customSlot: slot)
        if let data = try? JSONEncoder().encode(persisted),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            check(decoded.profile == .scene(.heavyBass)
                  && decoded.customSlot?.sceneBase == .heavyBass
                  && decoded.customSlot?.bass == staticCheck.bass,
                  "场景与完整低音配置可无损持久化")
        } else {
            check(false, "场景与完整低音配置可无损持久化", "JSON 编解码失败")
        }

        print(failures == 0 ? "\n✓ 全部通过（\(failures) 个失败）" : "\n✗ \(failures) 项失败")
        return failures == 0
    }

    // MARK: - 5. 电平表弹道

    static func runMeterTest() -> Bool {
        print("=== JEQ 电平表弹道校验 ===\n")
        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            if ok {
                print("  ✓ \(label)")
            } else {
                failures += 1
                print("  ✗ \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
            }
        }
        func db(_ v: Float) -> Float { v > 0 ? 20 * log10(v) : -120 }

        let b = MeterBallistics()
        var raw = MeterRaw()
        raw.inPeak = (0.5, 0.25)
        raw.inRMS = (0.35, 0.18)
        raw.outPeak = (0.9, 0.8)
        raw.outRMS = (0.6, 0.5)

        let s1 = b.update(raw, now: 100)
        check(abs(s1.inputL.peak - 0.5) < 1e-5, "峰值立即显示")
        check(abs(s1.inputR.peak - 0.25) < 1e-5, "左右声道独立累计")
        check(abs(s1.inputL.hold - 0.5) < 1e-5, "峰值保持初始化")

        let silent = MeterRaw()
        let s2 = b.update(silent, now: 100.05)
        let decayed: Float = 0.5 * pow(Float(10), -24 * 0.05 / 20)
        check(abs(s2.inputL.peak - decayed) < 0.005, "峰值按 24 dB/s 回落",
              String(format: "%.4f vs %.4f", s2.inputL.peak, decayed))
        check(abs(s2.inputL.hold - 0.5) < 1e-4, "保持值不随回落立刻下降")

        let s3 = b.update(silent, now: 101.0)
        check(abs(s3.inputL.hold - 0.5) < 1e-3, "1.3 s 内仍保持峰值")
        let s4 = b.update(silent, now: 101.4)
        check(s4.inputL.hold < 0.5, "超过保持时间后保持值回落",
              String(format: "hold=%.3f", s4.inputL.hold))

        var clipRaw = MeterRaw()
        clipRaw.inClip = true
        clipRaw.outClip = true
        let c1 = b.update(clipRaw, now: 200)
        check(c1.inputClip && c1.outputClip, "输入削波 / 输出限幅立即点亮")
        let c2 = b.update(MeterRaw(), now: 201.0)
        check(c2.inputClip && c2.outputClip, "指示灯保持 1.6 s")
        let c3 = b.update(MeterRaw(), now: 201.7)
        check(!c3.inputClip && !c3.outputClip, "1.6 s 后指示灯熄灭")

        let smooth = MeterBallistics()
        var steady = MeterRaw()
        steady.inRMS = (0.35, 0.35)
        for i in 0..<50 { _ = smooth.update(steady, now: 10 + Double(i) * 0.02) }
        let s5 = smooth.update(steady, now: 11.0)
        check(abs(s5.inputL.rms - 0.35) < 0.002, "RMS 平滑后收敛到真实均方值",
              String(format: "rms=%.4f", s5.inputL.rms))
        check(s5.inputL.rms <= s5.inputL.peak || s5.inputL.peak == 0,
              "RMS 不会超过峰值")

        print(failures == 0 ? "\n✓ 全部通过（\(failures) 个失败）" : "\n✗ \(failures) 项失败")
        return failures == 0
    }

    // MARK: - 3. 离屏渲染面板（无辅助功能权限时的 UI 验证手段）

    @MainActor
    static func runSnapshot() {
        let state = AppState.shared
        state.showAdvanced = CommandLine.arguments.contains("--advanced")
        if CommandLine.arguments.contains("--demo-heavy") {
            state.persistPaused = true
            state.apply(.heavyBass)
        }
        if CommandLine.arguments.contains("--demo-modules") {
            state.persistPaused = true
            for kind in InstrumentKind.allCases { state.setInstrument(kind, preset: 2, gainDB: 3) }
        }
        // 没有音频输入时电平表全是 0，离屏渲染看不出排版；喂一组固定读数
        state.meterDemoLevels = true
        state.refreshStatus()
        let view = PanelView(state: state, snapshotMode: true)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("✗ 渲染失败")
            return
        }
        // --out <目录> 可指定输出位置；默认系统临时目录
        let args = CommandLine.arguments
        var outDir = FileManager.default.temporaryDirectory
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            outDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        let path = outDir
            .appendingPathComponent(state.showAdvanced ? "jeq_panel_adv.png" : "jeq_panel.png").path
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("✓ 面板已渲染: \(path)  尺寸 \(img.size)")
        } catch {
            print("✗ 写入 \(path) 失败: \(error.localizedDescription)")
        }
    }
}
