import AppKit
import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit

// Проба S2 (план §3, OQ-13): звук одного приложения через process tap или ScreenCaptureKit.
// Журнал — в stdout строками с меткой времени от старта; run.sh собирает его через
// `open --stdout`. Ключевые строки: READY (данные пошли), t=N (уровни за секунду),
// EVENT … (смена устройства, уход приложения, ошибки потока), DONE.

setlinebuf(stdout)
let startedAt = Date()
func log(_ s: String) {
    print(String(format: "[%7.2f] ", Date().timeIntervalSince(startedAt)) + s)
}

func usage() -> Never {
    print("""
    Probe tap|sck (--app ИМЯ | --pid N) [--seconds 60] [--out КАТАЛОГ] [--mic] [--mono] [--all]
          [--tap-only] [--rate 48000]
    Probe list [--sck]      процессы Core Audio (и приложения SCK — спросит «Запись экрана»)
    Probe preflight         состояние разрешений без диалогов
    """)
    exit(64)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { usage() }
args.removeFirst()

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func cpuLine() -> String {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    let user = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
    let sys = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    let wall = Date().timeIntervalSince(startedAt)
    return String(format: "cpu_user=%.2f cpu_sys=%.2f wall=%.1f cpu_pct=%.1f", user, sys, wall, (user + sys) / wall * 100)
}

func resolveTarget() -> Target {
    if let p = value("--pid").flatMap({ pid_t($0) }) {
        let app = NSRunningApplication(processIdentifier: p)
        return Target(pid: p, name: app?.localizedName ?? "pid \(p)", bundleID: app?.bundleIdentifier)
    }
    guard let name = value("--app") else { usage() }
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == name
    }
    guard let app = apps.first else {
        log("ERROR приложение «\(name)» не запущено")
        exit(2)
    }
    if apps.count > 1 { log("несколько процессов «\(name)»: \(apps.map(\.processIdentifier)); беру первый") }
    return Target(pid: app.processIdentifier, name: app.localizedName ?? name, bundleID: app.bundleIdentifier)
}

func listCoreAudioProcesses() {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
        log("ERROR список процессов Core Audio недоступен"); return
    }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects)
    log("core audio процессов: \(objects.count)")
    for obj in objects {
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &pid)
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(obj, &runAddr, 0, nil, &runSize, &running)
        let bundle = DeviceWatch.string(obj, kAudioProcessPropertyBundleID)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "-"
        log("  obj=\(obj) pid=\(pid) output=\(running) bundle=\(bundle) name=\(name)")
    }
}

let bundleVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
log("probe pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "-") version=\(bundleVersion) stamp=\(buildStamp) exe=\(CommandLine.arguments[0])")
log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

switch mode {
case "preflight":
    log("screen_capture_preflight=\(CGPreflightScreenCaptureAccess())")
    log("mic_auth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = разрешено)")
    log("tap: предварительной проверки нет — только попытка создать tap")
    exit(0)
case "list":
    listCoreAudioProcesses()
    if flag("--sck") {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        log("sck приложений: \(content.applications.count)")
        for app in content.applications.sorted(by: { $0.processID < $1.processID }) {
            log("  pid=\(app.processID) bundle=\(app.bundleIdentifier) name=\(app.applicationName)")
        }
    }
    exit(0)
case "miccompare":
    let secs = value("--seconds").flatMap { Int($0) } ?? 8
    let onlyCapture = flag("--only-capture")
    let onlyEngine = flag("--only-engine")
    do {
        try MicCompare().run(seconds: secs, withCapture: !onlyEngine, withEngine: !onlyCapture)
    } catch {
        log("ERROR miccompare: \(error)")
    }
    log("DONE")
    exit(0)
case "tap", "sck":
    break
default:
    usage()
}

var options = CaptureOptions()
options.mono = flag("--mono")
options.all = flag("--all")
options.tapOnlyAggregate = flag("--tap-only")
options.rate = value("--rate").flatMap { Int($0) } ?? 48000
let seconds = value("--seconds").flatMap { Int($0) } ?? 60
let withMic = flag("--mic")
let outDir = URL(fileURLWithPath: value("--out") ?? NSString(string: "~/ASR/spikes/appaudio").expandingTildeInPath)
let target = resolveTarget()
guard args.isEmpty else { log("ERROR лишние аргументы: \(args)"); usage() }

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let stampFormatter = DateFormatter()
stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
let wavURL = outDir.appendingPathComponent("\(mode)-\(stampFormatter.string(from: startedAt)).wav")

log("mode=\(mode) target=\(target.name) pid=\(target.pid) bundle=\(target.bundleID ?? "-") options=\(options) seconds=\(seconds) mic=\(withMic)")
let outputDevice = DeviceWatch.defaultOutputDevice()
log("default_output: \(DeviceWatch.describe(outputDevice)) rate=\(DeviceWatch.nominalRate(outputDevice))")
DeviceWatch.watchDefaultOutput { log("EVENT default_output_changed: \($0)") }

let meter = Meter(label: "app")
let micMeter = Meter(label: "mic")
let wav = try WAVWriter(url: wavURL)
let capturer: Capturer = mode == "tap"
    ? TapCapture(target: target, options: options)
    : SCKCapture(target: target, options: options)
let mic = MicCapture()
var finished = false

func finish(_ reason: String) {
    guard !finished else { return }
    finished = true
    capturer.stop()
    if withMic { mic.stop() }
    wav.close()
    log("DONE reason=\(reason) total_frames=\(meter.totalFrames) wav=\(wavURL.path) \(cpuLine())")
}

let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { finish("signal \(sig)"); exit(0) }
    src.resume()
    return src
}

let startClock = Date()
do {
    try await capturer.start(
        onChunk: { chunk in meter.add(chunk); wav.write(chunk) },
        onEvent: { log("EVENT \($0)") })
} catch {
    log("ERROR start: \(error)")
    wav.close()
    exit(1)
}
log(String(format: "READY format=%@ start_took=%.2f", capturer.formatDescription, Date().timeIntervalSince(startClock)))
if withMic {
    do {
        try mic.start { micMeter.add($0) }
        log("mic format=\(mic.formatDescription)")
    } catch {
        log("ERROR mic: \(error)")
    }
}

var targetGone = false
for sec in 1...max(seconds, 1) {
    try await Task.sleep(nanoseconds: 1_000_000_000)
    var line = "t=\(sec) \(meter.flushLine())"
    if withMic { line += " | \(micMeter.flushLine())" }
    log(line)
    if !targetGone, kill(target.pid, 0) != 0 {
        targetGone = true
        log("EVENT target_process_gone pid=\(target.pid)")
    }
    if sec % 10 == 0 { log(cpuLine()) }
}
finish("seconds elapsed")
exit(0)
