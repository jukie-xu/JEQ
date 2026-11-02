// tap_spike.swift — 可行性验证：进程 tap + 聚合设备 + 单 IOProc 零拷贝环回
// 目标：证明 (1) 能建 tap (2) 能建含 tap 的聚合设备 (3) IOProc 能同时拿到 tap 输入
//      与物理输出缓冲，且处于同一时钟域 (4) 处理后的样本确实写进了输出缓冲。
import Foundation
import CoreAudio
import AudioToolbox

func fourCC(_ s: OSStatus) -> String {
    let v = UInt32(bitPattern: s)
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    let txt = String(bytes: bytes, encoding: .ascii) ?? "????"
    return "\(s) '\(txt)'"
}

@inline(__always) func die(_ s: OSStatus, _ what: String) -> Never {
    FileHandle.standardError.write("FATAL \(what): \(fourCC(s))\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 基本查询

func defaultOutputDevice() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return dev
}

func deviceUID(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid)
    if st != noErr { return "" }
    return uid as String
}

func nominalSampleRate(_ dev: AudioObjectID) -> Double {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
    return rate
}

/// 某 scope 下的流格式（取第一条流）
func streamFormat(_ dev: AudioObjectID, input: Bool) -> AudioStreamBasicDescription? {
    let scope: AudioObjectPropertyScope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
    let count = Int(size) / MemoryLayout<AudioStreamID>.size
    var streams = [AudioStreamID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &streams) == noErr else { return nil }

    var faddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyVirtualFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var asize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(streams[0], &faddr, 0, nil, &asize, &asbd) == noErr else { return nil }
    return asbd
}

func describe(_ f: AudioStreamBasicDescription) -> String {
    let flags = f.mFormatFlags
    let fmt: String
    if f.mFormatID == kAudioFormatLinearPCM {
        let f32 = (flags & kAudioFormatFlagIsFloat) != 0
        let packed = (flags & kAudioFormatFlagIsPacked) != 0
        let nonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
        fmt = "LPCM \(f32 ? "float" : "int")\(f.mBitsPerChannel) \(packed ? "packed" : "unpacked") \(nonInterleaved ? "non-interleaved" : "interleaved")"
    } else {
        fmt = "fmtID \(f.mFormatID)"
    }
    return "\(fmt) ch=\(f.mChannelsPerFrame) sr=\(f.mSampleRate) framesPerPacket=\(f.mFramesPerPacket) bytesPerFrame=\(f.mBytesPerFrame)"
}

// MARK: - 主流程

let outDev = defaultOutputDevice()
guard outDev != AudioObjectID(kAudioObjectUnknown) else { die(-1, "no default output device") }
let outUID = deviceUID(outDev)
print("▸ 默认输出设备: id=\(outDev)  uid=\(outUID)  sr=\(nominalSampleRate(outDev))")

// 1) 建 tap：全局立体声，排除自己（避免递归），tap 期间静音原输出
let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDesc.uuid = UUID()
tapDesc.name = "SubEQ Spike Tap"
tapDesc.muteBehavior = .mutedWhenTapped
tapDesc.isPrivate = true

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
guard tapStatus == noErr else { die(tapStatus, "AudioHardwareCreateProcessTap") }
print("▸ tap 已创建: id=\(tapID) uuid=\(tapDesc.uuid.uuidString)")

// 2) 建聚合设备：主时钟=物理输出，tap 走 drift compensation
let aggUID = "com.subEq.spike.\(UUID().uuidString)"
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "SubEQ Spike",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
        kAudioSubTapDriftCompensationKey: true,
    ]],
    kAudioAggregateDeviceTapAutoStartKey: true,
]
var aggID = AudioObjectID(kAudioObjectUnknown)
let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard aggStatus == noErr else { die(aggStatus, "AudioHardwareCreateAggregateDevice") }
print("▸ 聚合设备已创建: id=\(aggID)")

if let f = streamFormat(aggID, input: true) { print("  agg input : \(describe(f))") } else { print("  agg input : <none>") }
if let f = streamFormat(aggID, input: false) { print("  agg output: \(describe(f))") } else { print("  agg output: <none>") }

// 3) 单 IOProc 读取 tap 输入 + 写物理输出
let captureFrames = 48000 * 4
var inFloat: [Float] = []
var outFloat: [Float] = []
inFloat.reserveCapacity(captureFrames * 2)
outFloat.reserveCapacity(captureFrames * 2)

var inPeak: Float = 0
var outPeak: Float = 0
var callbackCount = 0

var procID: AudioDeviceIOProcID?
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
    callbackCount += 1
    let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outBL = UnsafeMutableAudioBufferListPointer(outData)

    // 取第一路输入（tap）第一通道做 RMS 探测，同时把整帧复制到输出缓冲
    if let inBuf = inBL.first, let inPtr = inBuf.mData?.assumingMemoryBound(to: Float.self) {
        let n = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.size
        var i = 0
        while i < n {
            let v = inPtr[i]
            if abs(v) > inPeak { inPeak = abs(v) }
            i += 1
        }
        if inFloat.count < captureFrames * 2 {
            for i in 0..<n { inFloat.append(inPtr[i]) }
        }
    }

    // 直接透传：把输入按通道拷到输出（形状一致时）
    for (idx, outBuf) in outBL.enumerated() {
        guard let outPtr = outBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let outN = Int(outBuf.mDataByteSize) / MemoryLayout<Float>.size
        if idx < inBL.count, let inPtr = inBL[idx].mData?.assumingMemoryBound(to: Float.self) {
            let inN = Int(inBL[idx].mDataByteSize) / MemoryLayout<Float>.size
            let n = min(outN, inN)
            for i in 0..<n {
                outPtr[i] = inPtr[i]
                if abs(outPtr[i]) > outPeak { outPeak = abs(outPtr[i]) }
            }
            if n < outN { for i in n..<outN { outPtr[i] = 0 } }
            if outFloat.count < captureFrames * 2 {
                for i in 0..<n { outFloat.append(outPtr[i]) }
            }
        } else {
            for i in 0..<outN { outPtr[i] = 0 }
        }
    }
}
guard ioStatus == noErr else { die(ioStatus, "AudioDeviceCreateIOProcIDWithBlock") }

let startStatus = AudioDeviceStart(aggID, procID)
guard startStatus == noErr else { die(startStatus, "AudioDeviceStart") }
print("▸ IOProc 已启动，采样 4 秒…")

Thread.sleep(forTimeInterval: 4.0)

AudioDeviceStop(aggID, procID)
if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }

print("▸ 回调次数: \(callbackCount)")
print("▸ 输入峰值: \(inPeak)   输出峰值: \(outPeak)")
print("▸ 采样样本数: in=\(inFloat.count) out=\(outFloat.count)")

// 4) 落盘以便离线分析（Float32 裸流）
try? Data(bytes: inFloat, count: inFloat.count * 4).write(to: URL(fileURLWithPath: "/tmp/subeq_in.raw"))
try? Data(bytes: outFloat, count: outFloat.count * 4).write(to: URL(fileURLWithPath: "/tmp/subeq_out.raw"))

AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
print("▸ 清理完成")
