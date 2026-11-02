import SwiftUI
import AppKit

// MARK: - 通用

private func nodeTint(_ gainDB: Float) -> Color {
    if gainDB > 0.05 { return .orange }
    if gainDB < -0.05 { return .blue }
    return .gray
}

private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

// MARK: - 数值滑杆

/// 以中点为原点的双向填充滑杆。
/// 用系统 Slider 时增益 0 会显示成"填了一半"，对 EQ 增益是误导性表意。
struct GainSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = -12...12
    var step: Float = 0.5
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 7
            let w = max(geo.size.width - inset * 2, 1)
            let h: CGFloat = 5
            let mid = inset + w / 2
            let frac = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
                               / (range.upperBound - range.lowerBound))
            let x = inset + w * frac
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.20))
                    .frame(width: w, height: h)
                    .offset(x: inset)
                Capsule().fill(tint.opacity(0.9))
                    .frame(width: abs(x - mid), height: h)
                    .offset(x: min(x, mid))
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().stroke(Color.gray.opacity(0.45), lineWidth: 0.6))
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.18), radius: 1.2, y: 0.6)
                    .offset(x: x - 6.5)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = Float(min(max((g.location.x - inset) / w, 0), 1))
                var v = range.lowerBound + f * (range.upperBound - range.lowerBound)
                v = (v / step).rounded() * step
                if v != value { value = v }
            })
        }
        .frame(height: 18)
    }
}

// MARK: - 行组件

struct BandSlider: View {
    var title: String
    var subtitle: String
    @Binding var value: Float
    var tint: Color
    var range: ClosedRange<Float> = -12...12
    var step: Float = 0.5

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1f dB", value))
                    .font(mono(10))
                    .foregroundStyle(value > 0.05 ? tint : (value < -0.05 ? .blue : .secondary))
                    .frame(width: 58, alignment: .trailing)
            }
            GainSlider(value: $value, range: range, step: step, tint: tint)
        }
    }
}

struct ToggleRow: View {
    var title: String
    var hint: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11))
                Text(hint).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

// MARK: - 电平表

/// 显示范围 −54…0 dBFS
private let meterFloorDB: Float = -54

private func meterDB(_ v: Float) -> Float { v > 0 ? 20 * log10(v) : -120 }

private func meterFraction(_ db: Float) -> CGFloat {
    CGFloat(min(max((db - meterFloorDB) / -meterFloorDB, 0), 1))
}

private let meterGradient = LinearGradient(
    stops: [
        .init(color: Color.green.opacity(0.7), location: 0.0),
        .init(color: Color.green, location: 0.55),
        .init(color: Color.yellow, location: 0.70),
        .init(color: Color.orange, location: 0.86),
        .init(color: Color.red, location: 0.94),
        .init(color: Color.red, location: 1.0),
    ],
    startPoint: .leading,
    endPoint: .trailing)

private let meterTicks: [Float] = [-48, -36, -24, -12, -6, 0]

/// 单声道一条：底轨 + 峰值渐变条 + RMS 白线 + 峰值保持细线 + 刻度
private struct MeterChannelBars: View {
    var channel: MeterChannelSample

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let peakW = channel.peak > 0 ? max(1.5, w * meterFraction(meterDB(channel.peak))) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.gray.opacity(0.13))

                ForEach(meterTicks, id: \.self) { t in
                    Rectangle()
                        .fill(Color.gray.opacity(t == 0 ? 0.32 : 0.14))
                        .frame(width: 0.5)
                        .offset(x: w * meterFraction(t))
                }

                if peakW > 0 {
                    Rectangle()
                        .fill(meterGradient)
                        .frame(width: w)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: peakW)
                        }
                }

                if channel.rms > 0.0002 {
                    Rectangle()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 1.2, height: 3.2)
                        .offset(x: min(w - 1.2, w * meterFraction(meterDB(channel.rms))))
                }

                if channel.hold > 0.0002 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 1.2)
                        .offset(x: max(0, min(w - 1.2, w * meterFraction(meterDB(channel.hold)) - 0.6)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .frame(height: 5)
    }
}

private struct MeterRow: View {
    var label: String
    var left: MeterChannelSample
    var right: MeterChannelSample
    var clipped: Bool
    var clipHint: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .leading)
            VStack(spacing: 1.5) {
                MeterChannelBars(channel: left)
                MeterChannelBars(channel: right)
            }
            Text(dbText)
                .font(mono(8.5, .medium))
                .foregroundStyle(valueColor)
                .frame(width: 34, alignment: .trailing)
            Circle()
                .fill(clipped ? Color.red : Color.gray.opacity(0.16))
                .frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(Color.gray.opacity(clipped ? 0 : 0.3), lineWidth: 0.5))
                .help(clipHint)
        }
        .frame(height: 13)
    }

    private var peakDB: Float {
        let p = max(left.peak, right.peak)
        return p > 0 ? 20 * log10(p) : -120
    }

    private var dbText: String {
        peakDB <= -60 ? "−∞" : String(format: "%+.0f", peakDB)
    }

    private var valueColor: Color {
        if peakDB > -3 { return .red }
        if peakDB > -12 { return .orange }
        return .secondary
    }
}

private struct MeterScale: View {
    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 22)
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                ForEach(meterTicks, id: \.self) { t in
                    Text(t == 0 ? "0" : String(format: "%+.0f", t))
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .position(x: min(max(w * meterFraction(t), 9), w - 9), y: 4)
                }
            }
            .frame(height: 9)
            Text("dB")
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            Color.clear.frame(width: 6)
        }
    }
}

struct LevelMeter: View {
    @ObservedObject var state: AppState

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { _ in
            let m = state.pollMeters()
            VStack(spacing: 2) {
                MeterRow(label: "IN", left: m.inputL, right: m.inputR,
                         clipped: m.inputClip, clipHint: "输入削波（≥ 0 dBFS）")
                MeterRow(label: "OUT", left: m.outputL, right: m.outputR,
                         clipped: m.outputClip, clipHint: "限幅器介入或输出接近 0 dBFS")
                MeterScale()
            }
        }
        .help("亮条＝峰值，白线＝RMS，细线＝峰值保持；每行上条＝左声道、下条＝右声道；右侧圆点：IN 削波 / OUT 限幅介入")
    }
}

// MARK: - 静态曲线预览（离屏截图用，ImageRenderer 不渲染 NSView）

struct CurvePreview: View {
    var state: AppState

    var body: some View {
        Canvas { ctx, size in
            let minF: Float = 20
            let maxF: Float = 20_000
            let maxDB: Float = 18
            let minDB: Float = -18

            func x(_ f: Float) -> CGFloat {
                CGFloat(log(max(f, minF) / minF) / log(maxF / minF)) * size.width
            }
            func y(_ db: Float) -> CGFloat {
                CGFloat((maxDB - min(max(db, minDB), maxDB)) / (maxDB - minDB)) * size.height
            }
            func label(_ f: Float) -> String {
                f >= 1_000 ? String(format: "%.2g kHz", f / 1_000) : String(format: "%.0f Hz", f)
            }

            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
            ctx.fill(bg, with: .color(Color(nsColor: .textBackgroundColor).opacity(0.55)))
            ctx.stroke(bg, with: .color(.gray.opacity(0.25)), lineWidth: 0.8)

            var grid = Path()
            for f in [Float(20), 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] {
                grid.move(to: CGPoint(x: x(f), y: 0))
                grid.addLine(to: CGPoint(x: x(f), y: size.height))
            }
            for db in stride(from: Float(-18), through: 18, by: 6) {
                grid.move(to: CGPoint(x: 0, y: y(db)))
                grid.addLine(to: CGPoint(x: size.width, y: y(db)))
            }
            ctx.stroke(grid, with: .color(.gray.opacity(0.18)), lineWidth: 0.5)

            let zeroY = y(0)
            var curve = Path()
            var fill = Path()
            let steps = 200
            for i in 0...steps {
                let t = Float(i) / Float(steps)
                let f = minF * pow(maxF / minF, t)
                let g = state.settings.effectiveCurveDB(at: f)
                let p = CGPoint(x: CGFloat(t) * size.width, y: y(g))
                if i == 0 {
                    curve.move(to: p)
                    fill.move(to: CGPoint(x: p.x, y: zeroY))
                    fill.addLine(to: p)
                } else {
                    curve.addLine(to: p)
                    fill.addLine(to: p)
                }
            }
            fill.addLine(to: CGPoint(x: size.width, y: zeroY))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.orange.opacity(0.35), Color.orange.opacity(0.02)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)))

            ctx.stroke(curve, with: .color(.orange), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            for b in state.settings.bands {
                // 节点直接画在控制点位置，插值曲线按定义经过它
                let p = CGPoint(x: x(b.freq), y: y(b.gainDB))
                let r: CGFloat = 4.8
                let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(b.enabled ? nodeTint(b.gainDB) : .gray.opacity(0.4)))
                ctx.stroke(dot, with: .color(.white), lineWidth: 1.4)

                let ly = p.y + 14 > size.height - 4 ? p.y - 10 : p.y + 10
                ctx.draw(Text(label(b.freq))
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(Color.secondary),
                         at: CGPoint(x: p.x, y: ly),
                         anchor: .center)
            }
        }
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15), lineWidth: 0.5))
    }
}

// MARK: - 主面板

struct PanelView: View {
    @ObservedObject var state: AppState
    var snapshotMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 上半区包一层：ViewBuilder 每个 buildBlock 最多 10 个子视图，
            // 这里分组后给后续加控件留余量。
            VStack(alignment: .leading, spacing: 10) {
                header
                profilesSection
                bassModule
                editor
            }
            Divider().opacity(0.5)
            controlRow
            if state.showAdvanced {
                advanced
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider().opacity(0.5)
            footer
        }
        .padding(14)
        .frame(width: 384)
    }

    // MARK: 顶栏

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(statusColor.opacity(0.35), lineWidth: 3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.deviceName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(statusText).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(state.profile.isCustom ? "DIY" : state.profile.title)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(state.profile.isCustom
                                       ? Color.orange.opacity(0.16)
                                       : Color.gray.opacity(0.12))
                    )
                    .foregroundStyle(state.profile.isCustom ? Color.orange : Color.secondary)
                    .help(state.profile.title)
            }
            LevelMeter(state: state)
        }
    }

    private var statusText: String {
        var t = state.statusLine
        if state.latencyMs > 0 { t += String(format: " · 延迟 %.1f ms", state.latencyMs) }
        t += " · " + state.sampleRateText
        return t
    }

    private var statusColor: Color {
        if state.errorText != nil { return .red }
        return state.engine.isRunning ? .green : .gray
    }

    // MARK: 场景 / 经典预设 / DIY

    private var profilesSection: some View {
        VStack(spacing: 8) {
            sceneProfiles
            classicProfiles
        }
    }

    private var sceneProfiles: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text("场景模式").font(.system(size: 10, weight: .semibold))
                Text("标准 10 段 · 独立低音").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(ScenePreset.allCases) { scene in
                    sceneButton(scene)
                }
                diyCard
            }
        }
    }

    private var classicProfiles: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text("经典预设").font(.system(size: 10, weight: .semibold))
                Text("原版音色").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(Preset.allCases) { preset in
                    presetButton(preset)
                }
            }
        }
    }

    private var diySubtitle: String {
        guard let slot = state.customSlot else { return "改参数自动保存" }
        if let scene = slot.sceneBase { return "基于 \(scene.title)" }
        if let base = slot.base { return "基于 \(base.title)" }
        return "自定义音色"
    }

    private var diyCard: some View {
        let active = state.profile.isCustom
        let available = state.customSlot != nil
        return Button {
            state.applyCustomSlot()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: active ? "tray.full.fill" : "tray.full")
                        .font(.system(size: 8.5))
                    Text("DIY").font(.system(size: 10, weight: .semibold))
                }
                Text(diySubtitle)
                    .font(.system(size: 7.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .opacity(0.72)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.orange.opacity(0.9) : Color.gray.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(available ? Color.orange.opacity(active ? 0.0 : 0.5) : Color.gray.opacity(0.12),
                            lineWidth: 1)
            )
            .foregroundStyle(active ? .white : (available ? Color.primary : Color.secondary))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .contextMenu {
            if let _ = state.customSlot {
                if !active {
                    Button("用当前音效覆盖 DIY") { state.overwriteCustomWithPreset() }
                } else {
                    Button("回到基础预设") { state.revertToBasePreset() }
                }
                Button("删除 DIY") { state.deleteCustomSlot() }
            }
        }
        .help(available
              ? "点击载入 DIY；右键可回到基础预设、覆盖或删除"
              : "修改任意频段、低音或清晰度时，会自动保存成 DIY 卡片")
    }

    private func sceneButton(_ scene: ScenePreset) -> some View {
        let active = state.profile.scenePreset == scene
        let isBase = state.profile.baseScene == scene
        return Button {
            state.apply(scene)
        } label: {
            Text(scene.title)
                .font(.system(size: 9.5, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Color.orange.opacity(0.9) : Color.gray.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isBase ? Color.orange.opacity(0.55) : Color.clear, lineWidth: 1)
                )
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
        .help(scene.summary)
    }

    // MARK: 独立低音模块

    private var bassModule: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("低音模块").font(.system(size: 10, weight: .semibold))
                Text("低频单独处理").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                Spacer()
                Text(state.settings.bass.mode.title)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(state.settings.bass.mode == .off ? .secondary : Color.orange)
            }

            HStack(spacing: 4) {
                ForEach(BassMode.allCases) { mode in
                    bassModeButton(mode)
                }
            }

            if state.settings.bass.mode != .off {
                HStack(spacing: 7) {
                    Text("中心").font(.system(size: 9)).foregroundStyle(.secondary)
                    Picker("低音中心", selection: Binding(
                        get: { state.settings.bass.centerHz },
                        set: { state.setBassCenter($0) }
                    )) {
                        ForEach(BassSettings.centers, id: \.self) { hz in
                            Text(String(format: "%g Hz", hz)).tag(hz)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.mini)
                    .frame(width: 78)

                    Text("强度").font(.system(size: 9)).foregroundStyle(.secondary)
                    Picker("低音强度", selection: Binding(
                        get: { state.settings.bass.strength },
                        set: { state.setBassStrength($0) }
                    )) {
                        ForEach(BassStrength.allCases) { strength in
                            Text(strength.title).tag(strength)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 108)

                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.15), lineWidth: 0.7)
        )
    }

    private func bassModeButton(_ mode: BassMode) -> some View {
        let active = state.settings.bass.mode == mode
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { state.setBassMode(mode) }
        } label: {
            Text(mode.shortTitle)
                .font(.system(size: 9.5, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Color.orange.opacity(0.82) : Color(nsColor: .controlBackgroundColor))
                )
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
        .help(mode.summary)
    }

    private func presetButton(_ p: Preset) -> some View {
        let active: Bool = {
            if case let .preset(current) = state.profile { return current == p }
            return false
        }()
        let isBase = state.profile.isCustom && state.profile.basePreset == p

        return Button {
            state.apply(p)
        } label: {
            Text(p.title)
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Color.orange.opacity(0.9) : Color.gray.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isBase ? Color.orange.opacity(0.55) : Color.clear, lineWidth: 1)
                )
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
        .help(p.summary)
    }

    // MARK: 可编辑曲线

    private var editor: some View {
        VStack(spacing: 3) {
            Group {
                if snapshotMode {
                    CurvePreview(state: state)
                } else {
                    CurveEditor(state: state,
                                settings: state.settings,
                                selectedBandID: state.selectedBandID)
                }
            }
            .frame(height: 210)
            Text(state.settings.bandLayout == .standard10
                 ? "上下拖动频点＝调整该频段的效果增益；频点位置固定，不再整体拖动"
                 : "双击空白＝加节点 · 拖节点＝单点 · 拖曲线＝整体移动（⌥ 横向移频）")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    // MARK: 启用 / 更多

    private var controlRow: some View {
        HStack {
            Toggle("启用", isOn: $state.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Spacer()
            Text("\(state.settings.bands.count) 个点")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Button(state.showAdvanced ? "收起" : "更多") {
                withAnimation { state.showAdvanced.toggle() }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 8) {
            BandSlider(title: "清晰度", subtitle: "独立 2–6 kHz 模块",
                       value: Binding(get: { state.settings.clarityDB },
                                      set: { state.setClarity($0) }),
                       tint: .orange, range: -6...6, step: 0.5)

            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 9))
                    .foregroundStyle(state.settings.autoPreamp ? Color.green : Color.secondary)
                Text("防爆音固定余量")
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                Text(state.settings.autoPreamp
                     ? String(format: "%+.1f dB", state.settings.staticHeadroomDB)
                     : "未启用")
                    .font(mono(9.5, .medium))
                    .foregroundStyle(state.settings.autoPreamp ? Color.green : Color.secondary)
                    .help("按当前最终曲线的最大正增益一次性计算；只随模式/曲线变化，绝不随歌曲电平起伏")
            }

            HStack(spacing: 8) {
                Spacer()

                if state.settings.bandLayout == .freeform {
                    Button("对齐到标准 10 段") { state.alignToStandardBands() }
                        .buttonStyle(.link)
                        .font(.system(size: 9.5))
                        .help("保留当前曲线形状，重采样到 31.5 Hz–16 kHz 的标准中心频率")
                } else {
                    Text("标准 10 段 · 31.5 Hz–16 kHz")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }

            BandSlider(title: "响度微调", subtitle: "只改输出音量，不改频响",
                       value: Binding(get: { state.settings.trimDB },
                                      set: { state.setTrim($0) }),
                       tint: .teal)

            ToggleRow(title: "固定防爆音余量",
                      hint: "按最终曲线峰值固定预衰减，不随歌曲/电平变化",
                      isOn: Binding(get: { state.settings.autoPreamp },
                                    set: { state.setFlag(\.autoPreamp, $0) }))
            ToggleRow(title: "末级软限幅",
                      hint: "只处理极端瞬态；超过约 −0.22 dBFS 才介入",
                      isOn: Binding(get: { state.settings.limiter },
                                    set: { state.setFlag(\.limiter, $0) }))

            ToggleRow(title: "开机启动",
                      hint: state.launchAtLogin
                            ? "登录时自动运行（\(LaunchAtLogin.mechanismDescription)）"
                            : "登录 macOS 后自动启动 JEQ",
                      isOn: Binding(get: { state.launchAtLogin },
                                    set: { state.setLaunchAtLogin($0) }))
            if let e = state.launchAtLoginError {
                Text(e).font(.system(size: 9)).foregroundStyle(.red).textSelection(.enabled)
            }

            if let e = state.errorText {
                Text(e).font(.system(size: 9)).foregroundStyle(.red).textSelection(.enabled)
                Button("重试") { state.restartEngine() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("JEQ").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Button("重启引擎") { state.restartEngine() }
                .buttonStyle(.link).font(.system(size: 10))
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link).font(.system(size: 10))
        }
    }
}
