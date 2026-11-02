// tap_spike4.swift — 定型验证：物理设备只贡献输出通道，输入流仅剩 tap；正确解交错后量频谱
import Foundation
import CoreAudio
import AudioToolbox

func fourCC(_ s: OSStatus) -> String {
    let v = UInt32(bitPattern: s)
    let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return "\(s) '\(String(bytes: b, encoding: .ascii) ?? "????")'"
}
@inline(__always) func die(_ s: OSStatus, _ what: String) -> Never {
    FileHandle.standardError.write("FATAL \(what): \(fourCC(s))\n".data(using: .utf8)!); exit(1)
}
func defaultOutputDevice() -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(kAudioObjectUnknown); var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}
func deviceUID(_ dev: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var uid: CFString = "" as CFString; var s = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &uid) == noErr else { return "" }
    return uid as String
}
func nominalSampleRate(_ dev: AudioObjectID) -> Double {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var r: Float64 = 0; var s = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &r); return r
}

func goertzel(_ x: ArraySlice<Float>, _ f: Double, _ sr: Double) -> Double {
    let n = x.count; guard n > 0 else { return 0 }
    let k = Int(0.5 + Double(n) * f / sr); let w = 2 * Double.pi * Double(k) / Double(n)
    let c = 2 * cos(w); var s1 = 0.0, s2 = 0.0
    for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
    let re = s1 - s2 * cos(w), im = s2 * sin(w)
    return (re * re + im * im).squareRoot() / (Double(n) / 2)
}

let outDev = defaultOutputDevice()
let outUID = deviceUID(outDev)
let sr = nominalSampleRate(outDev)
print("▸ out device sr=\(sr)")

let td = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
td.uuid = UUID(); td.name = "SubEQ Core"; td.muteBehavior = .mutedWhenTapped; td.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
let s1 = AudioHardwareCreateProcessTap(td, &tapID)
guard s1 == noErr else { die(s1, "CreateProcessTap") }

// 关键：sub-device 只给输出通道，输入通道数置 0 → 聚合设备输入流只剩 tap
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "SubEQ Core",
    kAudioAggregateDeviceUIDKey: "com.subeq.core.\(UUID().uuidString)",
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceSubDeviceListKey: [[
        kAudioSubDeviceUIDKey: outUID,
        kAudioSubDeviceInputChannelsKey: 0,
        kAudioSubDeviceOutputChannelsKey: 2,
    ]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: td.uuid.uuidString,
                                       kAudioSubTapDriftCompensationKey: true]],
    kAudioAggregateDeviceTapAutoStartKey: true,
]
var aggID = AudioObjectID(kAudioObjectUnknown)
let s2 = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard s2 == noErr else { die(s2, "CreateAggregateDevice") }

var left: [Float] = []; left.reserveCapacity(48000 * 3)
var cb = 0; var inPeak: Float = 0; var layoutDone = false
var reportedFrames = 0

var procID: AudioDeviceIOProcID?
let io = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
    cb += 1
    let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    if !layoutDone {
        layoutDone = true
        print("  inBL=\(inBL.count) outBL=\(outBL.count)")
        for (i, b) in inBL.enumerated() { print("   in[\(i)] ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)") }
        for (i, b) in outBL.enumerated() { print("   out[\(i)] ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)") }
    }
    // 解交错取左声道
    let nCh = inBL.count
    if nCh >= 2 {
        // 非交错：每个 buffer 是单声道
        if let p = inBL[0].mData?.assumingMemoryBound(to: Float.self) {
            let n = Int(inBL[0].mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<n {
                let v = p[i]
                if abs(v) > inPeak { inPeak = abs(v) }
                if left.count < 48000 * 3 { left.append(v) }
            }
            if reportedFrames == 0 { reportedFrames = n }
        }
    } else if let b0 = inBL.first, let p = b0.mData?.assumingMemoryBound(to: Float.self) {
        let ch = max(1, Int(b0.mNumberChannels))
        let total = Int(b0.mDataByteSize) / MemoryLayout<Float>.size
        var i = 0
        while i < total {
            let v = p[i]
            if abs(v) > inPeak { inPeak = abs(v) }
            if left.count < 48000 * 3 { left.append(v) }
            i += ch
        }
        if reportedFrames == 0 { reportedFrames = total / ch }
    }
    // 透传（非交错按 buffer 对齐；交错按整体拷贝）
    if inBL.count == outBL.count {
        for i in 0..<outBL.count {
            guard let op = outBL[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let on = Int(outBL[i].mDataByteSize) / MemoryLayout<Float>.size
            if let ip = inBL[i].mData?.assumingMemoryBound(to: Float.self) {
                let inN = Int(inBL[i].mDataByteSize) / MemoryLayout<Float>.size
                for j in 0..<min(on, inN) { op[j] = ip[j] }
                if on > inN { for j in inN..<on { op[j] = 0 } }
            } else { for j in 0..<on { op[j] = 0 } }
        }
    } else if let ob = outBL.first, let op = ob.mData?.assumingMemoryBound(to: Float.self) {
        let on = Int(ob.mDataByteSize) / MemoryLayout<Float>.size
        let ch = max(1, Int(ob.mNumberChannels))
        var written = 0
        if let ib = inBL.first, let ip = ib.mData?.assumingMemoryBound(to: Float.self) {
            let inN = Int(ib.mDataByteSize) / MemoryLayout<Float>.size
            while written < on && written < inN { op[written] = ip[written]; written += 1 }
        }
        while written < on { op[written] = 0; written += 1 }
        _ = ch
    }
}
guard io == noErr else { die(io, "CreateIOProcID") }
guard AudioDeviceStart(aggID, procID) == noErr else { die(-1, "DeviceStart") }

let player = Process()
player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
player.arguments = ["/tmp/tone.wav"]
try? player.run()
Thread.sleep(forTimeInterval: 2.5)
if player.isRunning { player.terminate() }
AudioDeviceStop(aggID, procID)
if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
player.waitUntilExit()

print("▸ 回调=\(cb) 每回调帧=\(reportedFrames) 捕获=\(left.count) 峰值=\(inPeak)")
if left.count > 96000 {
    // 稳态段：跳过前 0.5s
    let seg = left[24000..<72000]
    let a60 = goertzel(seg, 60, sr), a1k = goertzel(seg, 1_000, sr)
    let a30 = goertzel(seg, 30, sr), a120 = goertzel(seg, 120, sr)
    print(String(format: "▸ 30Hz=%.5f 60Hz=%.5f 120Hz=%.5f 1kHz=%.5f", a30, a60, a120, a1k))
    print(String(format: "▸ 60Hz:1kHz = %.2f  (源信号 0.35:0.25 ≈ 1.40)", a60 / max(a1k, 1e-9)))
}

AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
