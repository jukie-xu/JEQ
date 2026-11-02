import Foundation
import SwiftUI
import AppKit

/// 离线 DSP 校验 + 实时链路校验。全部输出数值，不靠"听起来像"。
enum SelfTest {

    static let sr: Float = 48_000

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
