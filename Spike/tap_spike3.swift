// tap_spike3.swift — 诊断：逐 buffer 测峰值 + muteBehavior 变体对比
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
func goertzel(_ x: [Float], _ f: Double, _ sr: Double) -> Double {
    let n = x.count; guard n > 0 else { return 0 }
    let k = Int(0.5 + Double(n) * f / sr); let w = 2 * Double.pi * Double(k) / Double(n)
    let c = 2 * cos(w); var s1 = 0.0, s2 = 0.0
    for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
    let re = s1 - s2 * cos(w), im = s2 * sin(w)
    return (re * re + im * im).squareRoot() / (Double(n) / 2)
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mutedWhenTapped"
let mute: CATapMuteBehavior
switch mode {
case "unmuted": mute = .unmuted
case "muted": mute = .muted
default: mute = .mutedWhenTapped
}

let outDev = defaultOutputDevice()
let outUID = deviceUID(outDev)
let sr = nominalSampleRate(outDev)
print("▸ mode=\(mode)  device=\(outUID.prefix(28)) sr=\(sr)")

let td = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
td.uuid = UUID(); td.name = "SubEQ Diag"; td.muteBehavior = mute; td.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
let s1 = AudioHardwareCreateProcessTap(td, &tapID)
guard s1 == noErr else { die(s1, "CreateProcessTap") }

let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "SubEQ Diag",
    kAudioAggregateDeviceUIDKey: "com.subeq.diag.\(UUID().uuidString)",
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

var peaks: [Float] = [0, 0, 0, 0]
var bufs: [[Float]] = [[], [], [], []]
var streams: [Int] = [0, 0, 0, 0]
var cb = 0
var procID: AudioDeviceIOProcID?
let io = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
    cb += 1
    let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    for (bi, b) in inBL.enumerated() where bi < 4 {
        streams[bi] = Int(b.mNumberChannels)
        guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let total = Int(b.mDataByteSize) / MemoryLayout<Float>.size
        for i in 0..<total {
            let v = p[i]
            if abs(v) > peaks[bi] { peaks[bi] = abs(v) }
            if bufs[bi].count < 48000 { bufs[bi].append(v) }
        }
    }
    for (i, ob) in outBL.enumerated() {
        guard let op = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let on = Int(ob.mDataByteSize) / MemoryLayout<Float>.size
        for j in 0..<on { op[j] = 0 }   // 诊断期间输出静音，避免啸叫
        _ = i
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

print("▸ 回调=\(cb)  输入流数=\(streams.prefix(4))")
for bi in 0..<4 where streams[bi] > 0 {
    let mono = bufs[bi]
    guard mono.count >= 48000 else {
        print("  buf[\(bi)] 样本不足 \(mono.count)"); continue
    }
    let seg = Array(mono[12000..<min(60000, mono.count)])
    print(String(format: "  buf[%d] peak=%.5f 60Hz=%.5f 120Hz=%.5f 1kHz=%.5f",
                 bi, peaks[bi], goertzel(seg, 60, sr), goertzel(seg, 120, sr), goertzel(seg, 1_000, sr)))
}

AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
