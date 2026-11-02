// probe_vol2.swift — 逐 element 探测/设置音量，定位这块 USB 声卡到底把音量挂在哪个 element
import Foundation
import CoreAudio

func fourCC(_ s: OSStatus) -> String {
    let v = UInt32(bitPattern: s)
    let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return "\(s) '\(String(bytes: b, encoding: .ascii) ?? "????")'"
}
func defaultOutput() -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(0); var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}

let dev = defaultOutput()
let setTo: Float32? = CommandLine.arguments.count > 1 ? Float32(CommandLine.arguments[1]) : nil

for el in UInt32(0)...UInt32(4) {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: el)
    let has = AudioObjectHasProperty(dev, &a)
    var v: Float32 = 0; var s = UInt32(MemoryLayout<Float32>.size)
    let got = AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v)
    print("element \(el): has=\(has) get=\(fourCC(got)) val=\(has && got == noErr ? String(v) : "-")")

    if has, let target = setTo {
        var t = target
        let st = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &t)
        var after: Float32 = 0
        AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &after)
        print("   set \(target) → \(fourCC(st)) 读回=\(after)")
    }
}
