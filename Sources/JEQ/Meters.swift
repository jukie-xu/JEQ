import Foundation

// MARK: - 原始电平（音频线程 → UI）

/// 音频线程在两次 UI 读取之间累计的峰值与均方值。
/// 每秒几十次读取下这些数字只用来画表，丢一帧不影响任何判断，
/// 所以这里刻意不加锁 —— 音频线程不能为了显示等待。
struct MeterRaw {
    var inPeak: (Float, Float) = (0, 0)
    var outPeak: (Float, Float) = (0, 0)
    var inRMS: (Float, Float) = (0, 0)
    var outRMS: (Float, Float) = (0, 0)
    var inClip = false
    var outClip = false
}

// MARK: - 显示值

struct MeterChannelSample: Equatable {
    var peak: Float = 0
    var rms: Float = 0
    var hold: Float = 0
}

struct MeterSnapshot {
    var inputL = MeterChannelSample()
    var inputR = MeterChannelSample()
    var outputL = MeterChannelSample()
    var outputR = MeterChannelSample()
    var inputClip = false
    var outputClip = false
}

// MARK: - 表头弹道

/// 峰值：瞬态上升、24 dB/s 回落；RMS：快起慢落；
/// 峰值保持 1.3 s 后以 14 dB/s 下滑；削波指示灯亮 1.6 s。
final class MeterBallistics {
    private struct Ballistic {
        var peak: Float = 0
        var rms: Float = 0
        var hold: Float = 0
        var holdUntil: TimeInterval = 0
        var last: TimeInterval = 0
    }

    private var inL = Ballistic(), inR = Ballistic()
    private var outL = Ballistic(), outR = Ballistic()
    private var inClipUntil: TimeInterval = 0
    private var outClipUntil: TimeInterval = 0

    func update(_ raw: MeterRaw, now: TimeInterval) -> MeterSnapshot {
        var s = MeterSnapshot()
        s.inputL = step(&inL, raw.inPeak.0, raw.inRMS.0, now)
        s.inputR = step(&inR, raw.inPeak.1, raw.inRMS.1, now)
        s.outputL = step(&outL, raw.outPeak.0, raw.outRMS.0, now)
        s.outputR = step(&outR, raw.outPeak.1, raw.outRMS.1, now)
        if raw.inClip { inClipUntil = now + 1.6 }
        if raw.outClip { outClipUntil = now + 1.6 }
        s.inputClip = now < inClipUntil
        s.outputClip = now < outClipUntil
        return s
    }

    /// 面板重新打开时调用：丢掉上一轮的表头状态，避免显示成“最后一次看到的样子”
    func reset() {
        inL = Ballistic(); inR = Ballistic()
        outL = Ballistic(); outR = Ballistic()
        inClipUntil = 0
        outClipUntil = 0
    }

    private func step(_ b: inout Ballistic, _ peak: Float, _ rms: Float,
                      _ now: TimeInterval) -> MeterChannelSample {
        let dt: Float = b.last == 0 ? 0.05 : Float(min(max(now - b.last, 0.001), 0.5))
        b.last = now

        if peak >= b.peak {
            b.peak = peak
        } else {
            b.peak = linear(max(db(peak), db(b.peak) - 24 * dt))
        }

        let tau: Float = rms > b.rms ? 0.03 : 0.28
        b.rms += (rms - b.rms) * (1 - exp(-dt / tau))

        if peak >= b.hold {
            b.hold = peak
            b.holdUntil = now + 1.3
        } else if now > b.holdUntil {
            b.hold = linear(max(-60, db(b.hold) - 14 * dt))
        }

        return MeterChannelSample(peak: b.peak, rms: b.rms, hold: b.hold)
    }

    private func db(_ v: Float) -> Float { v > 0 ? 20 * log10(v) : -120 }
    private func linear(_ db: Float) -> Float { db <= -119 ? 0 : pow(10, db / 20) }

    /// 离屏截图用的固定读数：验证电平表排版与配色，不参与真机显示
    static func demoSnapshot() -> MeterSnapshot {
        func sample(_ peakDB: Float, _ rmsDB: Float, _ holdDB: Float) -> MeterChannelSample {
            MeterChannelSample(peak: pow(10, peakDB / 20),
                               rms: pow(10, rmsDB / 20),
                               hold: pow(10, holdDB / 20))
        }
        var s = MeterSnapshot()
        s.inputL = sample(-18, -25, -13)
        s.inputR = sample(-22, -29, -16)
        s.outputL = sample(-8, -14, -4)
        s.outputR = sample(-10, -17, -6)
        s.inputClip = false
        s.outputClip = true
        return s
    }
}
