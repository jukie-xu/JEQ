import AppKit
import SwiftUI
import Combine

// MARK: - SwiftUI 包装

/// 可直接在频响曲线上操作。
/// 拖动圆点 = 单点频率/增益；拖动曲线本体 = 整条曲线移动（⌥ = 横向移频）；
/// 双击空白 = 加节点，右键 = 菜单，方向键 = 微调，Delete = 删除。
struct CurveEditor: NSViewRepresentable {
    var state: AppState
    /// 数值型输入只为让 SwiftUI 感知到数据变化；绘制时仍读 state 的最新值。
    var settings: EQSettings
    var selectedBandID: UUID?

    func makeNSView(context: Context) -> CurveCanvasView {
        let v = CurveCanvasView(frame: .zero)
        v.state = state
        return v
    }

    func updateNSView(_ v: CurveCanvasView, context: Context) {
        v.state = state
        v.needsDisplay = true
    }
}

// MARK: - 画布

final class CurveCanvasView: NSView {
    /// 直接订阅 AppState：NSViewRepresentable 的 struct 里只存同一个对象引用时，
    /// SwiftUI 可能判定“视图没变”而跳过 updateNSView，导致滑杆改参数后曲线不重绘。
    /// 订阅 objectWillChange 后，任何参数变化都会主动 needsDisplay。
    weak var state: AppState? {
        didSet {
            guard state !== oldValue else { return }
            subscribeState()
        }
    }

    private var stateSubscription: AnyCancellable?

    private func subscribeState() {
        stateSubscription = state?.objectWillChange.sink { [weak self] _ in
            // objectWillChange 在属性写入之前发出，延后一拍再重绘才能读到新值
            DispatchQueue.main.async {
                self?.needsDisplay = true
            }
        }
    }

    private let minF: Float = 20
    private let maxF: Float = 20_000
    private let maxDB: Float = 18
    private let minDB: Float = -18

    private var hoverID: UUID?
    private var draggingID: UUID?
    private var hoveringCurve = false
    private var trackingAreaRef: NSTrackingArea?

    /// 整条曲线拖动：记录起始点与原始控制点，
    /// 每一帧都从原始值重算，避免多次累加导致曲线变形/漂移。
    private struct CurveDrag {
        var baseline: [Band]
        var start: NSPoint
        var shiftFreq: Bool
    }
    private var curveDrag: CurveDrag?

    private var contextBandID: UUID?
    private var contextAddFreq: Float?
    private var contextAddGain: Float = 0

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: 坐标换算

    private func x(for freq: Float, in rect: NSRect) -> CGFloat {
        let t = log(max(freq, minF) / minF) / log(maxF / minF)
        return CGFloat(t) * rect.width
    }

    private func freq(atX x: CGFloat, in rect: NSRect) -> Float {
        let t = Float(min(max(x / max(rect.width, 1), 0), 1))
        return minF * pow(maxF / minF, t)
    }

    private func y(for db: Float, in rect: NSRect) -> CGFloat {
        let t = (min(max(db, minDB), maxDB) - minDB) / (maxDB - minDB)
        return CGFloat(t) * rect.height
    }

    private func db(atY y: CGFloat, in rect: NSRect) -> Float {
        let t = Float(min(max(y / max(rect.height, 1), 0), 1))
        return minDB + t * (maxDB - minDB)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let state else { return }
        let settings = state.settings
        let rect = bounds
        guard rect.width > 1, rect.height > 1 else { return }

        // 背景
        let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.textBackgroundColor.withAlphaComponent(0.55).setFill()
        bg.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        // 曲线：控制点之间的插值，节点必然落在曲线上
        let steps = 260
        var points: [NSPoint] = []
        points.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let f = minF * pow(maxF / minF, t)
            let g = settings.effectiveCurveDB(at: f)
            points.append(NSPoint(x: CGFloat(t) * rect.width, y: y(for: g, in: rect)))
        }

        // 曲线下面积
        let zeroY = y(for: 0, in: rect)
        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: 0, y: zeroY))
        for p in points { fill.line(to: p) }
        fill.line(to: NSPoint(x: rect.width, y: zeroY))
        fill.close()
        NSColor.systemOrange.withAlphaComponent(0.10).setFill()
        fill.fill()

        // 网格
        let gridColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.5)
        let gridFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        let freqTicks: [Float] = [20, 30, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
        for f in freqTicks {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x(for: f, in: rect), y: 13))
            path.line(to: NSPoint(x: x(for: f, in: rect), y: rect.height - 4))
            path.lineWidth = 0.5
            gridColor.setStroke()
            path.stroke()

            let px = x(for: f, in: rect)
            let label = tickLabel(f)
            let textWidth = (label as NSString).size(withAttributes: [.font: gridFont]).width
            let lx = min(px + 2, rect.width - textWidth - 2)
            drawText(label, at: NSPoint(x: lx, y: 2), font: gridFont,
                     color: NSColor.secondaryLabelColor.withAlphaComponent(0.7))
        }
        for db in stride(from: Float(-18), through: 18, by: 6) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: y(for: db, in: rect)))
            path.line(to: NSPoint(x: rect.width, y: y(for: db, in: rect)))
            path.lineWidth = 0.5
            if db == 0 {
                NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
            } else {
                gridColor.setStroke()
            }
            path.stroke()
            if db != 0 {
                drawText(String(format: "%+d", Int(db)),
                         at: NSPoint(x: 4, y: y(for: db, in: rect) + 2),
                         font: gridFont, color: NSColor.secondaryLabelColor.withAlphaComponent(0.55))
            }
        }

        // 拖动整条曲线时留下原曲线虚线，方便看清移动了多少
        if let drag = curveDrag, !drag.baseline.isEmpty {
            var base = settings
            base.bands = drag.baseline
            let ghost = NSBezierPath()
            for i in 0...steps {
                let t = Float(i) / Float(steps)
                let f = minF * pow(maxF / minF, t)
                let p = NSPoint(x: CGFloat(t) * rect.width, y: y(for: base.eqCurveDB(at: f), in: rect))
                if i == 0 { ghost.move(to: p) } else { ghost.line(to: p) }
            }
            ghost.lineWidth = 1
            ghost.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
            ghost.stroke()
        }

        // 主曲线
        let curve = NSBezierPath()
        curve.move(to: points[0])
        for p in points.dropFirst() { curve.line(to: p) }
        curve.lineJoinStyle = .round

        // 悬停/拖动曲线本体时加一层柔光，提示“这条线可以整体抓”
        if hoveringCurve || curveDrag != nil {
            let glow = NSBezierPath()
            glow.move(to: points[0])
            for p in points.dropFirst() { glow.line(to: p) }
            glow.lineWidth = 9
            glow.lineJoinStyle = .round
            NSColor.systemOrange.withAlphaComponent(0.16).setStroke()
            glow.stroke()
        }

        curve.lineWidth = 2
        NSColor.systemOrange.setStroke()
        curve.stroke()

        // 节点：y 就是控制点的增益，曲线按定义经过它
        for b in settings.bands {
            let p = NSPoint(x: x(for: b.freq, in: rect), y: y(for: b.gainDB, in: rect))
            let selected = b.id == state.selectedBandID
            let hover = b.id == hoverID
            let r: CGFloat = (selected || hover) ? 6 : 4.8

            if selected || hover {
                let halo = NSBezierPath(ovalIn: NSRect(x: p.x - r - 3, y: p.y - r - 3,
                                                       width: (r + 3) * 2, height: (r + 3) * 2))
                nodeColor(b).withAlphaComponent(0.22).setFill()
                halo.fill()
            }

            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if b.enabled {
                nodeColor(b).setFill()
                dot.fill()
            } else {
                NSColor.controlBackgroundColor.setFill()
                dot.fill()
            }
            NSColor.white.withAlphaComponent(b.enabled ? 0.95 : 0.0).setStroke()
            dot.lineWidth = 1.4
            dot.stroke()
            if !b.enabled {
                NSColor.secondaryLabelColor.withAlphaComponent(0.7).setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
        }

        // 频点标签：贴在节点上，跟着节点一起移动
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        var placedLabels: [NSRect] = []
        for b in settings.bands.sorted(by: { $0.freq < $1.freq }) {
            let selected = b.id == state.selectedBandID
            let np = NSPoint(x: x(for: b.freq, in: rect), y: y(for: b.gainDB, in: rect))
            let text = labelFreq(b.freq)
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont]
            let size = (text as NSString).size(withAttributes: attrs)
            var lx = np.x - size.width / 2
            lx = min(max(lx, 3), rect.width - size.width - 3)
            var ly = np.y - size.height - 7          // 默认贴在节点下方
            if ly < 2 { ly = np.y + 7 }              // 靠近底部时改到上方
            let bgRect = NSRect(x: lx - 2.5, y: ly - 1.5,
                                width: size.width + 5, height: size.height + 3)
            if !selected, placedLabels.contains(where: { $0.intersects(bgRect) }) { continue }

            NSColor.textBackgroundColor.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3).fill()

            let color = !b.enabled ? NSColor.tertiaryLabelColor
                : (selected ? nodeColor(b) : NSColor.secondaryLabelColor)
            drawText(text, at: NSPoint(x: lx, y: ly), font: labelFont, color: color)
            placedLabels.append(bgRect)
        }

        // 只有拖动时在右上角显示数值；悬停/选中不再弹气泡，避免挡住操作
        if let id = draggingID, let b = settings.bands.first(where: { $0.id == id }) {
            var text = String(format: "%@ · %+.1f dB", freqText(b.freq), b.gainDB)
            if !b.enabled { text += " · 已禁用" }
            drawHUD(text, in: rect)
        } else if let drag = curveDrag, let first = drag.baseline.first,
                  let cur = settings.bands.first(where: { $0.id == first.id }) {
            if drag.shiftFreq {
                drawHUD(String(format: "整体移频 ×%.2f", cur.freq / max(first.freq, 0.001)), in: rect)
            } else {
                drawHUD(String(format: "整体移动 %+.1f dB", cur.gainDB - first.gainDB), in: rect)
            }
        }
    }

    /// 拖动时固定在右上角的参数读数，不跟着光标走
    private func drawHUD(_ text: String, in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: rect.width - size.width - 12,
                             y: rect.height - size.height - 8)
        let box = NSRect(x: origin.x - 5, y: origin.y - 3,
                         width: size.width + 10, height: size.height + 6)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.8
        path.stroke()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        if let b = band(at: p) {
            state?.selectBand(b.id)
            draggingID = b.id
            needsDisplay = true
            return
        }

        if state?.settings.bandLayout == .freeform, event.clickCount == 2 {
            addBand(at: p)
            return
        }

        // 自由曲线才允许抓整条曲线；标准 10 段只做各频段的增益调整。
        if state?.settings.bandLayout == .freeform, curveDistance(from: p) <= 8 {
            startCurveDrag(at: p, event: event)
            return
        }

        state?.selectBand(nil)
        draggingID = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let drag = curveDrag {
            applyCurveDrag(drag, to: p)
            NSCursor.closedHand.set()
            return
        }
        guard let state, let id = draggingID, state.band(id) != nil else { return }
        // 自由模式可横向改频；标准 10 段锁定中心频率，只改纵向增益。
        let f = roundFreq(freq(atX: p.x, in: bounds))
        let g = ((db(atY: p.y, in: bounds)) * 10).rounded() / 10
        state.updateBand(id) { band in
            if state.settings.bandLayout == .freeform { band.freq = f }
            band.gainDB = g
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        draggingID = nil
        curveDrag = nil
        needsDisplay = true
    }

    private func startCurveDrag(at p: NSPoint, event: NSEvent) {
        guard let state, state.settings.bandLayout == .freeform,
              !state.settings.bands.isEmpty else { return }
        state.selectBand(nil)
        draggingID = nil
        curveDrag = CurveDrag(baseline: state.settings.bands,
                              start: p,
                              shiftFreq: event.modifierFlags.contains(.option))
        needsDisplay = true
    }

    /// 纵向拖动 = 全部控制点增益整体平移；按住 ⌥ 横向拖动 = 频率整体等比缩放。
    /// 始终以拖动开始时的快照为基准计算，曲线形状不会因为多次事件累积而漂移。
    private func applyCurveDrag(_ drag: CurveDrag, to p: NSPoint) {
        guard let state else { return }

        if drag.shiftFreq {
            let startF = freq(atX: drag.start.x, in: bounds)
            let nowF = freq(atX: p.x, in: bounds)
            guard startF > 0, nowF > 0 else { return }
            let shifted = CurveShift.apply(drag.baseline, deltaDB: 0, ratio: nowF / startF)
            state.setBands(shifted)
        } else {
            let raw = db(atY: p.y, in: bounds) - db(atY: drag.start.y, in: bounds)
            let limits = CurveShift.allowedDeltaDB(drag.baseline)
            let rounded = (raw * 10).rounded() / 10
            let delta = min(max(rounded, limits.lowerBound), limits.upperBound)
            let shifted = CurveShift.apply(drag.baseline, deltaDB: delta, ratio: 1)
            state.setBands(shifted)
        }
        needsDisplay = true
    }

    private func addBand(at p: NSPoint) {
        guard let state else { return }
        guard state.settings.bandLayout == .freeform,
              state.settings.bands.count < EQSettings.maxBands else { return }
        let f = roundFreq(freq(atX: p.x, in: bounds))
        let g = ((db(atY: p.y, in: bounds)) * 10).rounded() / 10
        state.addBand(freq: f, gainDB: g)
        needsDisplay = true
    }

    // MARK: 悬停 / 光标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited,
                                         .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let node = band(at: p)
        let onCurve = node == nil && state?.settings.bandLayout == .freeform
            && curveDistance(from: p) <= 8
        if node?.id != hoverID || onCurve != hoveringCurve {
            hoverID = node?.id
            hoveringCurve = onCurve
            needsDisplay = true
        }
        if node != nil {
            NSCursor.pointingHand.set()
        } else if onCurve {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverID != nil || hoveringCurve {
            hoverID = nil
            hoveringCurve = false
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    // MARK: 键盘微调

    override func keyDown(with event: NSEvent) {
        guard let state, let id = state.selectedBandID, let b = state.band(id) else {
            super.keyDown(with: event)
            return
        }
        let coarse = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 126: state.setBandGain(id, b.gainDB + (coarse ? 1 : 0.1))     // ↑
        case 125: state.setBandGain(id, b.gainDB - (coarse ? 1 : 0.1))     // ↓
        case 123 where state.settings.bandLayout == .freeform:
            state.setBandFreq(id, b.freq / (coarse ? 1.15 : 1.02))         // ←
        case 124 where state.settings.bandLayout == .freeform:
            state.setBandFreq(id, b.freq * (coarse ? 1.15 : 1.02))         // →
        case 51, 117:                                                      // Delete
            if state.settings.bandLayout == .freeform, !event.isARepeat {
                state.removeBand(id)                                       // 防止长按连锁删段
            }
        case 53: state.selectBand(nil)                                     // Esc
        default: super.keyDown(with: event)
        }
        needsDisplay = true
    }

    // MARK: 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let state else { return nil }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        guard let b = band(at: p) else {
            guard state.settings.bandLayout == .freeform else { return nil }
            contextAddFreq = roundFreq(freq(atX: p.x, in: bounds))
            contextAddGain = ((db(atY: p.y, in: bounds)) * 10).rounded() / 10
            contextBandID = nil
            let menu = NSMenu()
            menu.autoenablesItems = false
            let add = NSMenuItem(title: "在此添加节点", action: #selector(menuAddBand), keyEquivalent: "")
            add.target = self
            add.isEnabled = state.settings.bands.count < EQSettings.maxBands
            menu.addItem(add)
            return menu
        }

        state.selectBand(b.id)
        contextBandID = b.id
        let menu = NSMenu()
        menu.autoenablesItems = false
        if state.settings.bandLayout == .freeform {
            let del = NSMenuItem(title: "删除此节点", action: #selector(menuDeleteBand), keyEquivalent: "")
            del.target = self
            menu.addItem(del)
        }

        let zero = NSMenuItem(title: "增益归零", action: #selector(menuZeroBand), keyEquivalent: "")
        zero.target = self
        menu.addItem(zero)

        if state.settings.bandLayout == .freeform {
            menu.addItem(.separator())
            let toggle = NSMenuItem(title: b.enabled ? "禁用此点" : "启用此点",
                                    action: #selector(menuToggleBand), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
        }
        return menu
    }

    @objc private func menuDeleteBand() {
        if let id = contextBandID { state?.removeBand(id) }
        needsDisplay = true
    }

    @objc private func menuZeroBand() {
        if let id = contextBandID { state?.resetBand(id) }
        needsDisplay = true
    }

    @objc private func menuToggleBand() {
        if let id = contextBandID, let b = state?.band(id) {
            state?.setBandEnabled(id, !b.enabled)
        }
        needsDisplay = true
    }

    @objc private func menuAddBand() {
        guard let state, let f = contextAddFreq else { return }
        state.addBand(freq: f, gainDB: contextAddGain)
        needsDisplay = true
    }

    // MARK: 工具

    /// 鼠标点到曲线的最近距离（按折线近似），用于判断是否抓住曲线本体
    private func curveDistance(from p: NSPoint) -> CGFloat {
        guard let state else { return .greatestFiniteMagnitude }
        let settings = state.settings
        let rect = bounds
        let steps = 180
        var best = CGFloat.greatestFiniteMagnitude
        var prev: NSPoint?
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let f = minF * pow(maxF / minF, t)
            let q = NSPoint(x: CGFloat(t) * rect.width,
            y: y(for: settings.effectiveCurveDB(at: f), in: rect))
            if let a = prev {
                let dx = q.x - a.x, dy = q.y - a.y
                let len2 = dx * dx + dy * dy
                var u: CGFloat = 0
                if len2 > 0 { u = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 }
                u = min(max(u, 0), 1)
                best = min(best, hypot(p.x - (a.x + dx * u), p.y - (a.y + dy * u)))
            }
            prev = q
        }
        return best
    }

    private func band(at p: NSPoint) -> Band? {
        guard let state else { return nil }
        return state.settings.bands.last { b in
            let bp = NSPoint(x: x(for: b.freq, in: bounds), y: y(for: b.gainDB, in: bounds))
            return hypot(bp.x - p.x, bp.y - p.y) <= 10
        }
    }

    private func roundFreq(_ f: Float) -> Float {
        if f < 100 { return (f * 2).rounded() / 2 }
        if f < 1_000 { return f.rounded() }
        if f < 10_000 { return (f / 5).rounded() * 5 }
        return (f / 10).rounded() * 10
    }

    /// 提升用橙色、衰减用蓝色、0 dB 用灰色
    private func nodeColor(_ b: Band) -> NSColor {
        if !b.enabled { return .secondaryLabelColor }
        if b.gainDB > 0.05 { return .systemOrange }
        if b.gainDB < -0.05 { return .systemBlue }
        return .systemGray
    }

    private func tickLabel(_ f: Float) -> String {
        f >= 1_000 ? String(format: "%gk", f / 1_000) : String(format: "%g", f)
    }

    private func freqText(_ f: Float) -> String {
        if f >= 1_000 { return String(format: "%.2f kHz", f / 1_000) }
        if f < 100 { return String(format: "%.1f Hz", f) }
        return String(format: "%.0f Hz", f)
    }

    private func labelFreq(_ f: Float) -> String {
        if f >= 1_000 { return String(format: "%.2g kHz", f / 1_000) }
        return String(format: "%.0f Hz", f)
    }

    private func drawText(_ text: String, at p: NSPoint, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: p, withAttributes: attrs)
    }
}
