import Foundation

/// 低音、乐器、人声、清晰度共享同一份频段所有权，开启顺序随设备保存。
enum ToneModule: String, Codable, CaseIterable {
    case bass, drums, strings, piano, vocals, clarity
    var instrument: InstrumentKind? { InstrumentKind(rawValue: rawValue) }
    var title: String {
        if let instrument { return instrument.title }
        return self == .bass ? "低音模块" : "清晰度模块"
    }
}

extension EQSettings {
    func moduleRange(_ module: ToneModule) -> ClosedRange<Float>? {
        if let kind = module.instrument {
            let value = instruments[kind]
            guard value.preset > 0 else { return nil }
            let shape = kind.presets[value.preset - 1]
            return max(20, shape.centerHz / pow(2, shape.widthOctaves))...min(20_000, shape.centerHz * pow(2, shape.widthOctaves))
        }
        if module == .bass {
            switch bass.mode {
            case .off: return nil
            case .natural: return max(20, bass.centerHz * 0.5)...min(20_000, bass.centerHz * 2)
            case .pure: return max(20, bass.centerHz * 0.7)...min(20_000, bass.centerHz * 1.6)
            case .subwoofer: return 20...min(20_000, bass.centerHz * 1.5)
            }
        }
        return abs(clarityDB) > 0.01 ? 1_600...6_000 : nil
    }

    var activeModuleOrder: [ToneModule] {
        var result: [ToneModule] = []
        for module in moduleOrder + ToneModule.allCases {
            if moduleRange(module) != nil, !result.contains(module) { result.append(module) }
        }
        return result
    }

    mutating func updateModuleOrder(_ module: ToneModule, reclaim: Bool) {
        var order = activeModuleOrder
        if reclaim { order.removeAll { $0 == module } }
        if moduleRange(module) != nil, !order.contains(module) { order.append(module) }
        moduleOrder = order
    }

    func moduleOwner(at freq: Float) -> ToneModule? {
        activeModuleOrder.first { moduleRange($0)?.contains(freq) == true }
    }

    private func rawModuleDB(_ module: ToneModule, at freq: Float) -> Float {
        if let kind = module.instrument { return instruments[kind].curveDB(at: freq, kind: kind) }
        if module == .bass { return bass.curveDB(at: freq) }
        return clarityCurveDB(at: freq)
    }

    /// 模块只在自己的有限频段内生效，先开启者占用优先。
    /// 频段内部独占，边界内侧 0.16 倍频程淡入淡出，避免硬切频谱。
    func lockedModulesDB(at freq: Float) -> Float {
        guard freq > 0 else { return 0 }
        var result: Float = 0, remaining: Float = 1
        for module in activeModuleOrder {
            guard let range = moduleRange(module), range.contains(freq) else { continue }
            let lower = range.lowerBound <= 20 ? Float.greatestFiniteMagnitude : log2(freq / range.lowerBound)
            let upper = range.upperBound >= 20_000 ? Float.greatestFiniteMagnitude : log2(range.upperBound / freq)
            let edge = min(lower, upper)
            let mask: Float = edge >= 0.16 ? 1 : (1 - cos(Float.pi * max(0, edge) / 0.16)) / 2
            result += remaining * mask * rawModuleDB(module, at: freq)
            remaining *= 1 - mask
            if remaining < 1e-7 { break }
        }
        return result
    }

    func moduleLockText(_ module: ToneModule) -> String {
        guard let range = moduleRange(module) else { return "关闭后释放频段" }
        var spans = [range]
        var blockers: [String] = []
        for earlier in activeModuleOrder {
            if earlier == module { break }
            guard let block = moduleRange(earlier), block.overlaps(range) else { continue }
            blockers.append(earlier.title)
            spans = spans.flatMap { span -> [ClosedRange<Float>] in
                guard span.overlaps(block) else { return [span] }
                var rest: [ClosedRange<Float>] = []
                if span.lowerBound < block.lowerBound { rest.append(span.lowerBound...block.lowerBound) }
                if span.upperBound > block.upperBound { rest.append(block.upperBound...span.upperBound) }
                return rest
            }
        }
        let owned = spans.map { String(format: "%.0f–%.0f Hz", $0.lowerBound, $0.upperBound) }.joined(separator: "、")
        let text = owned.isEmpty ? "当前频段已被占用" : "已锁定 " + owned
        return blockers.isEmpty ? text : text + "；重叠区由" + blockers.joined(separator: "、") + "优先"
    }
}
