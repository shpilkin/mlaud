import CoreAudio
import Foundation

/// Ветка (а): process tap на PID через CATapDescription + агрегатное устройство + IOProc.
final class TapCapture: Capturer {
    private let target: Target
    private let options: CaptureOptions
    private(set) var formatDescription = "не запущен"

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var subdeviceID = AudioObjectID(kAudioObjectUnknown)
    /// Входных потоков у поддевайса; nil — не прочитано.
    private var subdeviceInputStreams: Int? = 0
    private var procID: AudioDeviceIOProcID?
    private var tapUUID = ""
    private var tapFormat = AudioStreamBasicDescription()
    private let ioQueue = DispatchQueue(label: "tap.io")
    private var listeners: [AudioObjectPropertyAddress] = []
    private var listenerClientData: UnsafeMutableRawPointer?
    private var onEvent: (String) -> Void = { _ in }

    private let lock = NSLock()
    private var stopped = false
    private var callbacks = 0
    private var channels = 0
    private var nonInterleaved = false
    private var sampleRate = 0.0
    /// Смещение буфера выбранного (tap) потока в AudioBufferList IOProc.
    private var bufferOffset = 0

    init(target: Target, options: CaptureOptions) {
        self.target = target
        self.options = options
    }

    func start(onChunk: @escaping (AudioChunk) -> Void,
               onEvent: @escaping (String) -> Void) async throws {
        self.onEvent = onEvent
        do {
            try createTap()
            try createAggregate()
            try readInputFormat()
            try startIO(onChunk)
        } catch {
            stop()
            throw error
        }
    }

    // MARK: - Tap

    private func createTap() throws {
        let desc: CATapDescription
        if options.all {
            desc = options.mono
                ? CATapDescription(monoGlobalTapButExcludeProcesses: [])
                : CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        } else {
            let process = try processObject(for: target.pid)
            desc = options.mono
                ? CATapDescription(monoMixdownOfProcesses: [process])
                : CATapDescription(stereoMixdownOfProcesses: [process])
        }
        desc.name = "mlaud-probe"
        desc.uuid = UUID()
        tapUUID = desc.uuid.uuidString
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw ProbeError("AudioHardwareCreateProcessTap: \(statusText(status)) — разрешение «Запись системного звука» не дано или tap недоступен")
        }
        let formatStatus = read(tapID, kAudioTapPropertyFormat, &tapFormat)
        guard formatStatus == noErr else {
            throw ProbeError("формат tap не прочитан: \(statusText(formatStatus))")
        }
        formatDescription = formatText(tapFormat)
        let uid = DeviceWatch.string(tapID, kAudioTapPropertyUID)
        onEvent("tap_created id=\(tapID) uid=\(uid) desc_uuid=\(tapUUID) format=\(formatDescription)")
    }

    private func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr else {
            throw ProbeError("PID \(pid) → объект процесса Core Audio: \(statusText(status))")
        }
        guard object != kAudioObjectUnknown else {
            throw ProbeError("у процесса pid=\(pid) нет объекта в Core Audio: он ещё не выводил звук или PID неверен")
        }
        onEvent("process_object pid=\(pid) id=\(object)")
        return object
    }

    // MARK: - Aggregate device

    private func createAggregate() throws {
        let readUID = DeviceWatch.string(tapID, kAudioTapPropertyUID)
        let tapUID = readUID == "?" ? tapUUID : readUID
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "mlaud-probe-aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var subdevice = "none"
        if !options.tapOnlyAggregate {
            let output = DeviceWatch.defaultOutputDevice()
            let outputUID = DeviceWatch.string(output, kAudioDevicePropertyDeviceUID)
            if outputUID == "?" {
                onEvent("aggregate_warning: UID устройства вывода не прочитан, агрегат без поддевайса")
            } else {
                dict[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
                dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
                subdevice = outputUID
                subdeviceID = output
            }
        }
        let status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard status == noErr, aggID != kAudioObjectUnknown else {
            aggID = AudioObjectID(kAudioObjectUnknown)
            throw ProbeError("AudioHardwareCreateAggregateDevice: \(statusText(status))")
        }
        if subdeviceID != kAudioObjectUnknown {
            subdeviceInputStreams = try? inputStreams(of: subdeviceID).count
        }
        onEvent("aggregate id=\(aggID) subdevice=\(subdevice) subdevice_input_streams=\(subdeviceInputStreams.map(String.init) ?? "?") tap_uid=\(tapUID)")
    }

    private func inputStreams(of device: AudioObjectID) throws -> [AudioStreamID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
        guard status == noErr else { throw ProbeError("входные потоки устройства \(device): \(statusText(status))") }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams)
        guard status == noErr else { throw ProbeError("входные потоки устройства \(device): \(statusText(status))") }
        return streams
    }

    /// Ищет поток tap среди входных потоков агрегата: поддевайс вывода (AirPods, USB-гарнитура)
    /// приносит и свой микрофон, порядок tap-потоков в заголовках не задан.
    private func readInputFormat() throws {
        let streams = try inputStreams(of: aggID)
        guard !streams.isEmpty else { throw ProbeError("у агрегата нет входных потоков — tap не подхватился") }
        var formats: [AudioStreamBasicDescription] = []
        for (i, stream) in streams.enumerated() {
            var format = AudioStreamBasicDescription()
            let status = read(stream, kAudioStreamPropertyVirtualFormat, &format)
            guard status == noErr else { throw ProbeError("формат входного потока \(i) агрегата: \(statusText(status))") }
            formats.append(format)
            onEvent("aggregate_input stream=\(i) id=\(stream) format=\(formatText(format))")
        }

        let isTapLike: (AudioStreamBasicDescription) -> Bool = {
            $0.mFormatID == kAudioFormatLinearPCM
                && $0.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && $0.mBitsPerChannel == 32
                && $0.mChannelsPerFrame == self.tapFormat.mChannelsPerFrame
        }
        let candidates = formats.indices.filter { isTapLike(formats[$0]) }
        // По AudioHardware.h потоки поддевайсов идут первыми — tap ожидаем сразу после них.
        let expected = subdeviceInputStreams ?? -1
        let listing = formats.enumerated().map { "\($0): \(formatText($1))" }.joined(separator: "; ")
        let index: Int
        switch candidates.count {
        case 1:
            index = candidates[0]
        case 0:
            throw ProbeError("ни один входной поток агрегата не похож на tap \(formatText(tapFormat)): \(listing)")
        default:
            guard let expected = subdeviceInputStreams, candidates.contains(expected) else {
                throw ProbeError("несколько потоков похожи на tap \(candidates), ожидаемый индекс \(expected) не среди них: \(listing)")
            }
            index = expected
            onEvent("aggregate_input tap выбран по положению: индекс \(expected) из кандидатов \(candidates)")
        }
        let format = formats[index]
        guard format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
            throw ProbeError("вход агрегата без каналов или частоты: \(formatText(format))")
        }
        let offset = formats[..<index].reduce(0) {
            $0 + ($1.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int($1.mChannelsPerFrame) : 1)
        }
        formatDescription = formatText(format)
        onEvent("aggregate_input tap_stream=\(index) of \(streams.count) buffer_offset=\(offset) expected=\(expected)")
        lock.lock()
        channels = Int(format.mChannelsPerFrame)
        nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        sampleRate = format.mSampleRate
        bufferOffset = offset
        lock.unlock()
    }

    // MARK: - IO

    private func startIO(_ onChunk: @escaping (AudioChunk) -> Void) throws {
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handleIO(inInputData, onChunk)
        }
        guard status == noErr, procID != nil else {
            procID = nil
            throw ProbeError("AudioDeviceCreateIOProcIDWithBlock: \(statusText(status))")
        }
        listenerClientData = Unmanaged.passRetained(self).toOpaque()
        addListener(kAudioDevicePropertyDeviceIsRunning)
        addListener(kAudioDeviceProcessorOverload)
        let startStatus = AudioDeviceStart(aggID, procID)
        guard startStatus == noErr else { throw ProbeError("AudioDeviceStart: \(statusText(startStatus))") }
    }

    private func handleIO(_ input: UnsafePointer<AudioBufferList>, _ onChunk: (AudioChunk) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        callbacks += 1
        let needed = nonInterleaved ? channels : 1
        if callbacks == 1 {
            let frames = bufferOffset < list.count
                ? Int(list[bufferOffset].mDataByteSize) / max(4 * Int(list[bufferOffset].mNumberChannels), 4) : 0
            onEvent("first_io frames=\(frames) buffers=\(list.count) buffer_offset=\(bufferOffset) channels=\(channels) interleaved=\(!nonInterleaved)")
        }
        guard bufferOffset + needed <= list.count else { return }
        let totalBytes = list.reduce(0) { $0 + Int($1.mDataByteSize) }
        guard totalBytes > 0 else { return }

        var samples: [Float]
        if nonInterleaved {
            // Каждый канал — свой AudioBuffer; берём `channels` буферов начиная с bufferOffset.
            let buffers = (bufferOffset..<bufferOffset + channels).map { list[$0] }
            let frames = buffers.map { Int($0.mDataByteSize) / 4 }.min() ?? 0
            guard frames > 0 else { return }
            samples = [Float](repeating: 0, count: frames * channels)
            for (c, buf) in buffers.enumerated() {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
                for f in 0..<frames { samples[f * channels + c] = data[f] }
            }
        } else {
            let buf = list[bufferOffset]
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            let bufChannels = Int(buf.mNumberChannels)
            guard bufChannels > 0 else { return }
            let frames = Int(buf.mDataByteSize) / (4 * bufChannels)
            guard frames > 0 else { return }
            if bufChannels == channels {
                samples = Array(UnsafeBufferPointer(start: data, count: frames * channels))
            } else {
                samples = [Float](repeating: 0, count: frames * channels)
                for f in 0..<frames {
                    for c in 0..<min(channels, bufChannels) { samples[f * channels + c] = data[f * bufChannels + c] }
                }
            }
        }
        onChunk(AudioChunk(samples: samples, channels: channels, sampleRate: sampleRate))
    }

    // Слушатели — через C-proc: на macOS 26.5 AudioObjectRemovePropertyListenerBlock отдаёт noErr, а блок продолжает вызываться.
    private func addListener(_ selector: AudioObjectPropertySelector) {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListener(aggID, &addr, tapListenerProc, listenerClientData)
        if status == noErr {
            listeners.append(addr)
        } else {
            onEvent("listener \(fourCC(selector)) не установлен: \(statusText(status))")
        }
    }

    fileprivate func propertyChanged(_ selector: AudioObjectPropertySelector) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.aggID != kAudioObjectUnknown else { return }
            switch selector {
            case kAudioDevicePropertyDeviceIsRunning:
                var running: UInt32 = 0
                let s = self.read(self.aggID, kAudioDevicePropertyDeviceIsRunning, &running)
                self.onEvent("aggregate_is_running=\(running) status=\(self.statusText(s))")
            case kAudioDeviceProcessorOverload:
                self.onEvent("aggregate_processor_overload")
            default:
                break
            }
        }
    }

    // MARK: - Stop

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        guard !already else { return }

        if aggID != kAudioObjectUnknown {
            if let procID {
                report("AudioDeviceStop", AudioDeviceStop(aggID, procID))
                report("AudioDeviceDestroyIOProcID", AudioDeviceDestroyIOProcID(aggID, procID))
                self.procID = nil
            }
            for addr in listeners {
                var addr = addr
                report("AudioObjectRemovePropertyListener \(fourCC(addr.mSelector))",
                       AudioObjectRemovePropertyListener(aggID, &addr, tapListenerProc, listenerClientData))
            }
            listeners.removeAll()
            if let listenerClientData {
                Unmanaged<TapCapture>.fromOpaque(listenerClientData).release()
                self.listenerClientData = nil
            }
            report("AudioHardwareDestroyAggregateDevice", AudioHardwareDestroyAggregateDevice(aggID))
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            report("AudioHardwareDestroyProcessTap", AudioHardwareDestroyProcessTap(tapID))
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        onEvent("tap_stopped callbacks=\(callbacks)")
    }

    private func report(_ call: String, _ status: OSStatus) {
        if status != noErr { onEvent("\(call): \(statusText(status))") }
    }

    // MARK: - Helpers

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         _ value: inout T) -> OSStatus {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, UnsafeMutableRawPointer($0))
        }
    }

    private func statusText(_ status: OSStatus) -> String {
        "\(status) (\(fourCC(UInt32(bitPattern: status))))"
    }

    private func formatText(_ f: AudioStreamBasicDescription) -> String {
        let flags = f.mFormatFlags
        let kind = flags & kAudioFormatFlagIsFloat != 0 ? "float"
            : flags & kAudioFormatFlagIsSignedInteger != 0 ? "int" : "uint"
        return "\(kind)\(f.mBitsPerChannel) \(Int(f.mSampleRate)) Hz \(f.mChannelsPerFrame)ch"
            + " interleaved=\(flags & kAudioFormatFlagIsNonInterleaved == 0)"
            + " (formatID=\(fourCC(f.mFormatID)) flags=0x\(String(flags, radix: 16))"
            + " bytesPerFrame=\(f.mBytesPerFrame) framesPerPacket=\(f.mFramesPerPacket))"
    }
}

private func tapListenerProc(_ object: AudioObjectID, _ count: UInt32,
                             _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                             _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    let capture = Unmanaged<TapCapture>.fromOpaque(clientData).takeUnretainedValue()
    for i in 0..<Int(count) { capture.propertyChanged(addresses[i].mSelector) }
    return noErr
}

private func fourCC(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return "0x" + String(code, radix: 16)
}
