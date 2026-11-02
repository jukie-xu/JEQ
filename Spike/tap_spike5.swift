// tap_spike5.swift — 定型：tap 流位于输入流末尾；解交错取左声道；透传到输出
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

let td = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
td.uuid = UUID(); td.name = "SubEQ Core"; td.muteBehavior = .mutedWhenTapped; td.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
let s1 = AudioHardwareCreateProcessTap(td, &tapID)
guard s1 == noErr else { die(s1, "CreateProcessTap") }

let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "SubEQ Core",
    kAudioAggregateDeviceUIDKey: "com.subeq.core.\(UUID().uuidString)",
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: td.uuid.uuidString,
                                       kAudioSubTapDriftCompensationKey: true]],
    kAudioAggregateDeviceTapAutoStartKey: true,
]
var aggID = AudioObjectID(kAudioObjectUnknown)
let s2 = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard s2 == noErr else { die(s2, "CreateAggregateDevice") }

var left: [Float] = []; left.reserveCapacity(48000 * 3)
var cb = 0; var peak: Float = 0; var done = false; var tapIdx = -1; var framesPerCb = 0

var procID: AudioDeviceIOProcID?
let io = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
    cb += 1
    let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    if tapIdx < 0 { tapIdx = inBL.count - 1 }
    if !done {
        done = true
        print("  inBL=\(inBL.count)  outBL=\(outBL.count)  tapIdx=\(tapIdx)")
        for (i, b) in inBL.enumerated() { print("   in[\(i)] ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)") }
        for (i, b) in outBL.enumerated() { print("   out[\(i)] ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)") }
    }
    guard tapIdx < inBL.count,
          let ip = inBL[tapIdx].mData?.assumingMemoryBound(to: Float.self) else { return }
    let ch = max(1, Int(inBL[tapIdx].mNumberChannels))
    let total = Int(inBL[tapIdx].mDataByteSize) / MemoryLayout<Float>.size
    let frames = total / ch
    if framesPerCb == 0 { framesPerCb = frames }
    var f = 0
    while f < frames {
        let v = ip[f * ch]
        if abs(v) > peak { peak = abs(v) }
        if left.count < 48000 * 3 { left.append(v) }
        f += 1
    }
    // 透传：tap 左/右 → 输出左/右（仅单 buffer 交错输出的常见情形）
    if let ob = outBL.first, let op = ob.mData?.assumingMemoryBound(to: Float.self) {
        let och = max(1, Int(ob.mNumberChannels))
        let on = Int(ob.mDataByteSize) / MemoryLayout<Float>.size
        let oFrames = on / och
        let n = min(oFrames, frames)
        for i in 0..<n {
            for c in 0..<och {
                let srcC = min(c, ch - 1)
                op[i * och + c] = ip[i * ch + srcC]
            }
        }
        if n < oFrames { for i in (n * och)..<on { op[i] = 0 } }
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

print("▸ 回调=\(cb) frames/cb=\(framesPerCb) 捕获=\(left.count) 峰值=\(peak)")
if left.count > 96000 {
    let seg = left[24000..<72000]
    let a60 = goertzel(seg, 60, sr), a1k = goertzel(seg, 1_000, sr)
    print(String(format: "▸ 30Hz=%.5f 60Hz=%.5f 120Hz=%.5f 1kHz=%.5f",
                 goertzel(seg, 30, sr), a60, goertzel(seg, 120, sr), a1k))
    print(String(format: "▸ 60Hz:1kHz = %.2f  (期望 ≈ 1.40)  延迟=%.1f ms",
                 a60 / max(a1k, 1e-9), Double(framesPerCb) / sr * 1000))
}

AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
