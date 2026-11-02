// probe_volume.swift — 用 CoreAudio 直接读写默认输出音量标量，确认 tap 是音量前还是音量后
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
func getVol(_ dev: AudioObjectID) -> Float? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(dev, &a) else { return nil }
    var v: Float32 = 0; var s = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v) == noErr else { return nil }
    return v
}
func setVol(_ dev: AudioObjectID, _ v: Float32) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain)
    var val = v
    return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &val)
}
func muteState(_ dev: AudioObjectID) -> Int? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(dev, &a) else { return nil }
    var v: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v) == noErr else { return nil }
    return Int(v)
}

let d = defaultOutput()
print("device=\(d)")
print("初始音量标量:", getVol(d) as Any, " mute:", muteState(d) as Any)
print("set 1.0 →", fourCC(setVol(d, 1.0)))
print("读回:", getVol(d) as Any)
print("set 0.25 →", fourCC(setVol(d, 0.25)))
print("读回:", getVol(d) as Any)
