import Foundation

// 命令行诊断模式优先于 GUI
if CommandLine.arguments.contains("--selftest") {
    SelfTest.runDSP()
    exit(0)
}
if CommandLine.arguments.contains("--curvetest") {
    exit(SelfTest.runCurveTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--metertest") {
    exit(SelfTest.runMeterTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--modetest") {
    exit(SelfTest.runModeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("--snapshot") {
    MainActor.assumeIsolated { SelfTest.runSnapshot() }
    exit(0)
}
if CommandLine.arguments.contains("--liveproof") {
    SelfTest.runLiveProof()
    exit(0)
}

JEQApp.main()
