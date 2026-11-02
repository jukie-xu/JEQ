// probe_proc.swift — 查询 CoreAudio 进程对象列表，确认自己的 PID 是否已经成为音频对象
import Foundation
import CoreAudio
import AudioToolbox

func procObjects() -> [(AudioObjectID, pid_t)] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    let n = Int(size) / MemoryLayout<AudioObjectID>.size
    var list = [AudioObjectID](repeating: 0, count: n)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr
    else { return [] }
    var out: [(AudioObjectID, pid_t)] = []
    for o in list {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var s = UInt32(MemoryLayout<pid_t>.size)
        if AudioObjectGetPropertyData(o, &a, 0, nil, &s, &pid) == noErr {
            out.append((o, pid))
        }
    }
    return out
}

let me = getpid()
print("my pid = \(me)")

func report(_ tag: String) {
    let list = procObjects()
    print("[\(tag)] 进程对象数 = \(list.count)")
    if let hit = list.first(where: { $0.1 == me }) {
        print("  ✓ 自己已注册: objectID=\(hit.0)")
    } else {
        print("  ✗ 自己未注册")
    }
}

report("启动时")

// 起一个静音 IOProc，看是否会注册进程对象
let dev = { () -> AudioObjectID in
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var d = AudioObjectID(0); var s = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}()

var proc: AudioDeviceIOProcID?
let st = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, nil) { _, _, _, outData, _ in
    let bl = UnsafeMutableAudioBufferListPointer(outData)
    for b in bl {
        if let p = b.mData?.assumingMemoryBound(to: Float.self) {
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<n { p[i] = 0 }
        }
    }
}
print("IOProc 创建: \(st)")
if let p = proc { print("DeviceStart: \(AudioDeviceStart(dev, p))") }
Thread.sleep(forTimeInterval: 0.4)
report("IOProc 运行中")

if let p = proc {
    AudioDeviceStop(dev, p)
    AudioDeviceDestroyIOProcID(dev, p)
}
