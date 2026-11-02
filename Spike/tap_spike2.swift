// tap_spike2.swift — 自包含验证：spike 自己 spawn afplay，保证采集与播放重叠
import Foundation
import CoreAudio
import AudioToolbox

func fourCC(_ s: OSStatus) -> String {
    let v = UInt32(bitPattern: s)
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return "\(s) '\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
}
@inline(__always) func die(_ s: OSStatus, _ what: String) -> Never {
    FileHandle.standardError.write("FATAL \(what): \(fourCC(s))\n".data(using: .utf8)!)
    exit(1)
}
func defaultOutputDevice() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return dev
}
func deviceUID(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr else { return "" }
    return uid as String
}
func nominalSampleRate(_ dev: AudioObjectID) -> Double {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
    return rate
}
func bufferFrameSize(_ dev: AudioObjectID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v)
    return v
}

// Goertzel：在捕获数据上直接量 60Hz / 1kHz 幅度
func goertzel(_ x: [Float], _ f: Double, _ sr: Double) -> Double {
    let n = x.count
    guard n > 0 else { return 0 }
    let k = Int(0.5 + Double(n) * f / sr)
    let w = 2.0 * Double.pi * Double(k) / Double(n)
    let c = 2.0 * cos(w)
    var s1 = 0.0, s2 = 0.0
    for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
    let re = s1 - s2 * cos(w), im = s2 * sin(w)
    return (re * re + im * im).squareRoot() / (Double(n) / 2.0)
}

let outDev = defaultOutputDevice()
guard outDev != AudioObjectID(kAudioObjectUnknown) else { die(-1, "no default output") }
let outUID = deviceUID(outDev)
let sr = nominalSampleRate(outDev)
print("▸ 输出设备 id=\(outDev) sr=\(sr) bufferFrames=\(bufferFrameSize(outDev))")

let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDesc.uuid = UUID()
tapDesc.name = "SubEQ Spike Tap"
tapDesc.muteBehavior = .mutedWhenTapped
tapDesc.isPrivate = true

var tapID = AudioObjectID(kAudioObjectUnknown)
let st = AudioHardwareCreateProcessTap(tapDesc, &tapID)
guard st == noErr else { die(st, "CreateProcessTap") }
print("▸ tap id=\(tapID)")

let aggUID = "com.subeq.spike.\(UUID().uuidString)"
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
let st2 = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard st2 == noErr else { die(st2, "CreateAggregateDevice") }
print("▸ 聚合设备 id=\(aggID)")

let frames = 48000 * 3
var captured: [Float] = []
captured.reserveCapacity(frames)
var cb = 0
var inPeak: Float = 0
var layoutReported = false

var procID: AudioDeviceIOProcID?
let io = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
    cb += 1
    let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    if !layoutReported {
        layoutReported = true
        print("  inBL.count=\(inBL.count) outBL.count=\(outBL.count)")
        for (i, b) in inBL.enumerated() { print("  in[\(i)] ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)") }
        for (i, b) in outBL.enumerated() { print("  out[\(i)] ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)") }
    }
    // 交错格式：单 buffer 双声道。取左声道
    if let b0 = inBL.first, let p = b0.mData?.assumingMemoryBound(to: Float.self) {
        let total = Int(b0.mDataByteSize) / MemoryLayout<Float>.size
        let ch = Int(b0.mNumberChannels)
        var i = 0
        while i < total {
            let v = p[i]
            if abs(v) > inPeak { inPeak = abs(v) }
            if ch <= 1 || (i % ch) == 0, captured.count < frames { captured.append(v) }
            i += 1
        }
    }
    // 透传
    for (i, ob) in outBL.enumerated() {
        guard let op = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let on = Int(ob.mDataByteSize) / MemoryLayout<Float>.size
        if i < inBL.count, let ip = inBL[i].mData?.assumingMemoryBound(to: Float.self) {
            let inN = Int(inBL[i].mDataByteSize) / MemoryLayout<Float>.size
            for j in 0..<min(on, inN) { op[j] = ip[j] }
            if on > inN { for j in inN..<on { op[j] = 0 } }
        } else { for j in 0..<on { op[j] = 0 } }
    }
}
guard io == noErr else { die(io, "CreateIOProcID") }

let startSt = AudioDeviceStart(aggID, procID)
guard startSt == noErr else { die(startSt, "DeviceStart") }
print("▸ IOProc 已启动")

// 自己 spawn 播放器，保证采集窗口与播放重叠
let player = Process()
player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
player.arguments = ["/tmp/tone.wav"]
try? player.run()
print("▸ 已 spawn afplay pid=\(player.processIdentifier)")
Thread.sleep(forTimeInterval: 2.8)
if player.isRunning { player.terminate() }

AudioDeviceStop(aggID, procID)
if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
player.waitUntilExit()

print("▸ 回调次数=\(cb)  捕获单声道样本=\(captured.count)  峰值=\(inPeak)")
if captured.count > 24000 {
    // 取中段 1 秒做频谱
    let mid = captured.count / 2
    let seg = Array(captured[mid..<min(mid + 48000, captured.count)])
    let a60 = goertzel(seg, 60, sr)
    let a120 = goertzel(seg, 120, sr)
    let a1k = goertzel(seg, 1000, sr)
    let a4k = goertzel(seg, 4000, sr)
    print(String(format: "▸ 频谱: 60Hz=%.5f  120Hz=%.5f  1kHz=%.5f  4kHz=%.5f", a60, a120, a1k, a4k))
    print("▸ 低频/中频比 (60Hz : 1kHz) = \(String(format: "%.2f", a60 / max(a1k, 1e-9)))  期望 ≈ 1.40")
}
try? Data(bytes: captured, count: captured.count * 4).write(to: URL(fileURLWithPath: "/tmp/subeq_mono.raw"))

AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
print("▸ 清理完成")
