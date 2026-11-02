import Foundation

/// 二阶节（RBJ Audio EQ Cookbook）。Direct Form II Transposed，Float 运算。
struct BiquadCoeff {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var active: Bool = false

    static let passthrough = BiquadCoeff()

    /// 低架滤波：抬升/压低某个频率以下的整体能量，是"重低音"的主力
    static func lowShelf(freq: Float, gainDB: Float, slope: Float = 1.0, sampleRate: Float) -> BiquadCoeff {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * freq / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2)
        let sqA2a = 2 * sqrt(A) * alpha
        let b0 = A * ((A + 1) - (A - 1) * cosw + sqA2a)
        let b1 = 2 * A * ((A - 1) - (A + 1) * cosw)
        let b2 = A * ((A + 1) - (A - 1) * cosw - sqA2a)
        let a0 = (A + 1) + (A - 1) * cosw + sqA2a
        let a1 = -2 * ((A - 1) + (A + 1) * cosw)
        let a2 = (A + 1) + (A - 1) * cosw - sqA2a
        return normalized(b0, b1, b2, a0, a1, a2)
    }

    /// 峰值滤波：窄带精细补偿，用于 sub 频段"下潜"或削掉某个轰头频点
    static func peaking(freq: Float, gainDB: Float, q: Float, sampleRate: Float) -> BiquadCoeff {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * freq / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * max(q, 0.05))
        let b0 = 1 + alpha * A
        let b1 = -2 * cosw
        let b2 = 1 - alpha * A
        let a0 = 1 + alpha / A
        let a1 = -2 * cosw
        let a2 = 1 - alpha / A
        return normalized(b0, b1, b2, a0, a1, a2)
    }

    /// 高架滤波：给低音让位时轻削高频，避免整体发闷
    static func highShelf(freq: Float, gainDB: Float, slope: Float = 1.0, sampleRate: Float) -> BiquadCoeff {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * freq / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2)
        let sqA2a = 2 * sqrt(A) * alpha
        let b0 = A * ((A + 1) + (A - 1) * cosw + sqA2a)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
        let b2 = A * ((A + 1) + (A - 1) * cosw - sqA2a)
        let a0 = (A + 1) - (A - 1) * cosw + sqA2a
        let a1 = 2 * ((A - 1) - (A + 1) * cosw)
        let a2 = (A + 1) - (A - 1) * cosw - sqA2a
        return normalized(b0, b1, b2, a0, a1, a2)
    }

    private static func normalized(_ b0: Float, _ b1: Float, _ b2: Float,
                                   _ a0: Float, _ a1: Float, _ a2: Float) -> BiquadCoeff {
        var c = BiquadCoeff()
        c.b0 = b0 / a0; c.b1 = b1 / a0; c.b2 = b2 / a0
        c.a1 = a1 / a0; c.a2 = a2 / a0
        c.active = true
        return c
    }

    /// 单频点幅频响应（dB），用于画曲线与离线校验
    func magnitudeDB(at freq: Float, sampleRate: Float) -> Float {
        guard active else { return 0 }
        let w = 2 * Float.pi * freq / sampleRate
        let cosw = cos(w), sinw = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)
        let numRe = b0 + b1 * cosw + b2 * cos2
        let numIm = -(b1 * sinw + b2 * sin2)
        let denRe = 1 + a1 * cosw + a2 * cos2
        let denIm = -(a1 * sinw + a2 * sin2)
        let num = (numRe * numRe + numIm * numIm).squareRoot()
        let den = (denRe * denRe + denIm * denIm).squareRoot()
        guard den > 0 else { return 0 }
        return 20 * log10(max(num / den, 1e-9))
    }
}

/// 单个声道的滤波状态（2 阶 × N 节）
final class BiquadState {
    private var z1: UnsafeMutablePointer<Float>
    private var z2: UnsafeMutablePointer<Float>
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        z1 = .allocate(capacity: capacity); z1.initialize(repeating: 0, count: capacity)
        z2 = .allocate(capacity: capacity); z2.initialize(repeating: 0, count: capacity)
    }
    deinit { z1.deallocate(); z2.deallocate() }

    @inline(__always)
    func process(_ x: Float, coeffs: UnsafePointer<BiquadCoeff>, count: Int) -> Float {
        var y = x
        for k in 0..<count {
            let c = coeffs[k]
            if !c.active { continue }
            let out = c.b0 * y + z1[k]
            z1[k] = c.b1 * y - c.a1 * out + z2[k]
            z2[k] = c.b2 * y - c.a2 * out
            y = out
        }
        return y
    }

    func reset() {
        for i in 0..<capacity { z1[i] = 0; z2[i] = 0 }
    }
}
