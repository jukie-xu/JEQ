import Foundation
import CoreAudio
import AudioToolbox

enum EngineError: LocalizedError {
    case coreAudio(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(status, what):
            return "\(what) 失败 (\(EngineError.fourCC(status)))"
        }
    }

    static func fourCC(_ s: OSStatus) -> String {
        let v = UInt32(bitPattern: s)
        let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        let txt = String(bytes: b, encoding: .ascii) ?? "????"
        return "\(s) '\(txt)'"
    }
}

/// tap → 聚合设备 → 单 IOProc → 物理输出。
/// 关键事实（本机实测）：
///  1. 聚合设备的输入流 = [子设备自身输入流..., tap 流]；tap 流总在末尾。
///  2. tap 抓的是「音量前」的混音 → 写回设备时音量会再乘一次，必须反算补偿。
///  3. 单 IOProc 意味着输入输出同一时钟域，无累积漂移，实测 512 帧 ≈ 10.7ms。
final class TapEngine {
    let params = ParamStore()

    private(set) var isRunning = false
    private(set) var sampleRate: Float = 48_000
    private(set) var framesPerBuffer: Int = 0
    private(set) var outputDeviceName: String = ""
    private(set) var outputDeviceID: AudioObjectID = 0
    private(set) var lastError: String?

    /// 状态变化（起停、设备切换、报错）回调，主线程
    var onStateChange: (() -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var volumeListener: AudioObjectPropertyListenerBlock?

    private var states: [BiquadState] = (0..<ParamStore.maxChannels).map { _ in BiquadState(capacity: ParamStore.maxBands) }
    private var tapStreamIndex = -1

    /// 诊断用：把 DSP 前后的样本各存一份，供离线校验（仅 --liveproof 打开）
    final class CaptureBuffer {
        let capacity: Int
        let inBuf: UnsafeMutablePointer<Float>
        let outBuf: UnsafeMutablePointer<Float>
        var count = 0
        var active = false
        init(capacity: Int = 48_000 * 4) {
            self.capacity = capacity
            inBuf = .allocate(capacity: capacity); inBuf.initialize(repeating: 0, count: capacity)
            outBuf = .allocate(capacity: capacity); outBuf.initialize(repeating: 0, count: capacity)
        }
        deinit {
            inBuf.deinitialize(count: capacity); inBuf.deallocate()
            outBuf.deinitialize(count: capacity); outBuf.deallocate()
        }
        func reset() { count = 0 }
    }
    let capture = CaptureBuffer()

    // 供 UI 显示的电平累计值。音频线程只写，UI 读取后清零；
    // 读与清零之间最多少看见一个 buffer（约 10 ms），对表头没有影响。
    private var meterInPeakL: Float = 0
    private var meterInPeakR: Float = 0
    private var meterOutPeakL: Float = 0
    private var meterOutPeakR: Float = 0
    private var meterInSqL: Float = 0
    private var meterInSqR: Float = 0
    private var meterOutSqL: Float = 0
    private var meterOutSqR: Float = 0
    private var meterFrames: Int = 0
    private var meterInClip = false
    private var meterOutClip = false

    // MARK: - 设备查询

    static func defaultOutputDevice() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    static func uid(of dev: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr,
              let u = uid?.takeUnretainedValue() else { return "" }
        return u as String
    }

    static func name(of dev: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr,
              let n = name?.takeUnretainedValue() else { return "未知设备" }
        return n as String
    }

    static func nominalSampleRate(of dev: AudioObjectID) -> Float {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
        return Float(rate)
    }

    /// 设备音量：主 element 常为空，USB 设备一般挂在 element 1/2
    static func bufferFrameSize(of dev: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return 0 }
        return Int(v)
    }

    static func volume(of dev: AudioObjectID) -> Float {
        for el in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioObjectPropertyScopeOutput,
                                                  mElement: el)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr, v > 0 {
                return v
            }
        }
        return 1
    }

    private static func streamFormat(_ dev: AudioObjectID, input: Bool) -> AudioStreamBasicDescription? {
        let scope: AudioObjectPropertyScope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let n = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: 0, count: n)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &streams) == noErr else { return nil }
        var faddr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var asize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(streams[0], &faddr, 0, nil, &asize, &asbd) == noErr else { return nil }
        return asbd
    }


    /// 自己的 CoreAudio 进程对象（不是 PID！直接用 PID 会得到 kAudioHardwareBadObjectError）
    static func ownProcessObjectID() -> AudioObjectID? {
        let me = getpid()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let n = Int(size) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: 0, count: n)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr
        else { return nil }
        for o in list {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var s = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(o, &a, 0, nil, &s, &pid) == noErr, pid == me { return o }
        }
        return nil
    }

    // MARK: - 生命周期


    func start() {
        guard !isRunning else { return }
        do {
            try build()
            isRunning = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            teardown()
            isRunning = false
        }
        DispatchQueue.main.async { self.onStateChange?() }
    }

    func stop() {
        guard isRunning || aggID != AudioObjectID(kAudioObjectUnknown) else { return }
        teardown()
        isRunning = false
        DispatchQueue.main.async { self.onStateChange?() }
    }

    private func build() throws {
        guard let dev = Self.defaultOutputDevice() as AudioObjectID?, dev != AudioObjectID(kAudioObjectUnknown) else {
            throw EngineError.coreAudio(0, "找不到默认输出设备")
        }
        outputDeviceID = dev
        outputDeviceName = Self.name(of: dev)
        let devUID = Self.uid(of: dev)
        sampleRate = Self.nominalSampleRate(of: dev)

        // 必须排除自身：否则我们写回聚合设备的输出会被全局 tap 再次捕获，形成正反馈
        // 必须排除自身：否则写回聚合设备的输出会被全局 tap 再次捕获，形成正反馈
        let exclude = Self.ownProcessObjectID().map { [$0] } ?? []
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        tapDesc.uuid = UUID()
        tapDesc.name = "JEQ Tap"
        tapDesc.muteBehavior = .mutedWhenTapped
        tapDesc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        let s1 = AudioHardwareCreateProcessTap(tapDesc, &tap)
        guard s1 == noErr else { throw EngineError.coreAudio(s1, "创建系统音频 tap") }
        tapID = tap

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "JEQ",
            kAudioAggregateDeviceUIDKey: "com.jeq.aggregate",
            kAudioAggregateDeviceMainSubDeviceKey: devUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: devUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let s2 = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard s2 == noErr else { throw EngineError.coreAudio(s2, "创建聚合设备") }
        aggID = agg

        if let f = Self.streamFormat(agg, input: true) {
            sampleRate = Float(f.mSampleRate)
        }
        framesPerBuffer = Self.bufferFrameSize(of: agg)
        tapStreamIndex = -1
        resetMeters()
        for s in states { s.reset() }

        params.publish(AppState.shared.settings, sampleRate: sampleRate, deviceVolume: Self.volume(of: dev))

        var pid: AudioDeviceIOProcID?
        let io = AudioDeviceCreateIOProcIDWithBlock(&pid, agg, nil) { [weak self] _, inData, _, outData, _ in
            self?.render(inData: inData, outData: outData)
        }
        guard io == noErr else { throw EngineError.coreAudio(io, "创建 IOProc") }
        procID = pid

        let started = AudioDeviceStart(agg, pid)
        guard started == noErr else { throw EngineError.coreAudio(started, "启动音频设备") }

        installVolumeListener(on: dev)
    }

    private func teardown() {
        if let l = volumeListener, outputDeviceID != 0 {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioObjectPropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(outputDeviceID, &addr, DispatchQueue.main, l)
            volumeListener = nil
        }
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggID, procID)
            if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapStreamIndex = -1
        resetMeters()
    }

    private func installVolumeListener(on dev: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let vol = Self.volume(of: dev)
            self.params.publish(AppState.shared.settings, sampleRate: self.sampleRate, deviceVolume: vol)
        }
        volumeListener = block
        AudioObjectAddPropertyListenerBlock(dev, &addr, DispatchQueue.main, block)
        // 音量挂在 element 1/2 的设备要单独挂监听
        for el in [UInt32(1), UInt32(2)] {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                               mScope: kAudioObjectPropertyScopeOutput,
                                               mElement: el)
            if AudioObjectHasProperty(dev, &a) {
                AudioObjectAddPropertyListenerBlock(dev, &a, DispatchQueue.main, block)
            }
        }
    }

    /// 参数变化时由 UI 调用。deviceVolume 参数已不参与计算，
    /// 不再每次拖动都去查询 HAL。
    func republish() {
        params.publish(AppState.shared.settings, sampleRate: sampleRate, deviceVolume: 1)
    }

    // MARK: - 电平表数据

    /// UI 每帧取走自上次以来的峰值/RMS 并清零。
    /// 每声道分别累计，因此表头能显示立体声；RMS 用均方值算，不是峰值近似。
    func takeMeterRaw() -> MeterRaw {
        var raw = MeterRaw()
        raw.inPeak = (meterInPeakL, meterInPeakR)
        raw.outPeak = (meterOutPeakL, meterOutPeakR)
        if meterFrames > 0 {
            let n = Float(meterFrames)
            raw.inRMS = (sqrt(meterInSqL / n), sqrt(meterInSqR / n))
            raw.outRMS = (sqrt(meterOutSqL / n), sqrt(meterOutSqR / n))
        }
        raw.inClip = meterInClip
        raw.outClip = meterOutClip
        resetMeters()
        return raw
    }

    private func resetMeters() {
        meterInPeakL = 0; meterInPeakR = 0
        meterOutPeakL = 0; meterOutPeakR = 0
        meterInSqL = 0; meterInSqR = 0
        meterOutSqL = 0; meterOutSqR = 0
        meterFrames = 0
        meterInClip = false
        meterOutClip = false
    }

    // MARK: - 音频线程

    private func render(inData: UnsafePointer<AudioBufferList>, outData: UnsafeMutablePointer<AudioBufferList>) {
        params.refreshSnapshot()
        if params.snapReset {
            for s in states { s.reset() }
        }

        let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outBL = UnsafeMutableAudioBufferListPointer(outData)
        guard !inBL.isEmpty, !outBL.isEmpty else { return }

        if tapStreamIndex < 0 || tapStreamIndex >= inBL.count {
            tapStreamIndex = inBL.count - 1
        }
        let ti = tapStreamIndex

        let inch = max(1, Int(inBL[ti].mNumberChannels))
        let inFrames = Int(inBL[ti].mDataByteSize) / MemoryLayout<Float>.size / inch
        guard inFrames > 0 else { return }
        if framesPerBuffer == 0 { framesPerBuffer = inFrames }
        _ = inFrames

        let planarInput = inBL.count > 1 && inch == 1
        let coeffs = params.snapshotPointer
        let nBands = params.snapCount
        let pre = params.snapPreamp
        let make = params.snapMakeup
        let clip = params.snapLimiter
        // 输出达到软限幅膝点就认作“限幅介入”；关了限幅则按 0 dBFS 算削波
        let outClipThreshold: Float = clip ? DSPLimits.outputWarnLevel : 0.999

        for (oi, ob) in outBL.enumerated() {
            guard let op = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let och = max(1, Int(ob.mNumberChannels))
            let oFrames = Int(ob.mDataByteSize) / MemoryLayout<Float>.size / och
            let frames = min(oFrames, inFrames)
            let chPairs = min(och, ParamStore.maxChannels)

            var inPkL: Float = 0, inPkR: Float = 0
            var outPkL: Float = 0, outPkR: Float = 0
            var inSqL: Float = 0, inSqR: Float = 0
            var outSqL: Float = 0, outSqR: Float = 0
            var inClipped = false
            var outClipped = false

            for c in 0..<och {
                let srcBuf = planarInput ? inBL[min(c, inBL.count - 1)] : inBL[ti]
                guard let ip = srcBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = planarInput ? 1 : inch
                let offset = planarInput ? 0 : min(c, inch - 1)
                let st = states[min(c, chPairs - 1)]
                var chInPeak: Float = 0
                var chOutPeak: Float = 0
                var chInSq: Float = 0
                var chOutSq: Float = 0
                for f in 0..<frames {
                    var x = ip[f * stride + offset]
                    if !x.isFinite { x = 0 }
                    let ax = abs(x)
                    if ax > chInPeak { chInPeak = ax }
                    if ax >= 0.999 { inClipped = true }
                    chInSq += x * x
                    var y = x * pre
                    if nBands > 0 { y = st.process(y, coeffs: coeffs, count: nBands) }
                    y *= make
                    // 限幅必须是最后一级，否则增益会突破保护阈值
                    if clip {
                        y = DSPLimits.softLimit(y)
                    }
                    let ay = abs(y)
                    if ay > chOutPeak { chOutPeak = ay }
                    if ay >= outClipThreshold { outClipped = true }
                    chOutSq += y * y
                    if c == 0, capture.active, capture.count < capture.capacity {
                        capture.inBuf[capture.count] = x
                        capture.outBuf[capture.count] = y
                        capture.count += 1
                    }
                    op[f * och + c] = y
                }
                if c == 0 {
                    inPkL = chInPeak; inSqL = chInSq
                    outPkL = chOutPeak; outSqL = chOutSq
                } else if c == 1 {
                    inPkR = chInPeak; inSqR = chInSq
                    outPkR = chOutPeak; outSqR = chOutSq
                }
            }
            // 单声道设备：右声道与左声道同值，表头仍显示两条，避免看起来缺一路
            if och < 2 {
                inPkR = inPkL; inSqR = inSqL
                outPkR = outPkL; outSqR = outSqL
            }
            // 输出通道比输入多时静音补齐
            if och > chPairs {
                for c in chPairs..<och {
                    for f in 0..<frames { op[f * och + c] = 0 }
                }
            }
            if frames < oFrames {
                for f in frames..<oFrames { for c in 0..<och { op[f * och + c] = 0 } }
            }
            _ = oi

            meterInPeakL = max(meterInPeakL, inPkL)
            meterInPeakR = max(meterInPeakR, inPkR)
            meterOutPeakL = max(meterOutPeakL, outPkL)
            meterOutPeakR = max(meterOutPeakR, outPkR)
            // 面板关着时没人读数：峰值照常保留，均方值最多累计 2 秒，
            // 否则再次打开面板会看到一段“历史平均”而不是当前电平
            if meterFrames < 96_000 {
                meterInSqL += inSqL; meterInSqR += inSqR
                meterOutSqL += outSqL; meterOutSqR += outSqR
                meterFrames += frames
            }
            if inClipped { meterInClip = true }
            if outClipped { meterOutClip = true }
        }
    }
}
