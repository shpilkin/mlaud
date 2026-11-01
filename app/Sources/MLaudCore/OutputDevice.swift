import CoreAudio
import Foundation

/// Устройство вывода по умолчанию: наушники или динамики (FR-12.1; образец poc/appaudio/probe/DeviceWatch.swift).
public enum OutputDevice {
    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    public static func defaultDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    public static func name(_ id: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        return status == noErr ? (name as String) : "устройство \(id)"
    }

    /// kAudioDevicePropertyTransportType.
    public static func transportType(_ id: AudioDeviceID) -> UInt32? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// kAudioDevicePropertyDataSource (область вывода) → имя ("Internal Speakers"/"Headphones").
    public static func dataSourceName(_ id: AudioDeviceID) -> String? {
        var source = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr else { return nil }
        let sourcePtr = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        defer { sourcePtr.deallocate() }
        sourcePtr.initialize(to: source)
        let namePtr = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        defer { namePtr.deallocate() }
        namePtr.initialize(to: nil)
        var translation = AudioValueTranslation(
            mInputData: UnsafeMutableRawPointer(sourcePtr), mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
            mOutputData: UnsafeMutableRawPointer(namePtr), mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
        var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        address.mSelector = kAudioDevicePropertyDataSourceNameForIDCFString
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &translationSize, &translation)
        guard status == noErr, let name = namePtr.pointee else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Чистая эвристика: встроенный транспорт и источник без "Headphones"/"Наушники" → динамики.
    public static func isLikelySpeakers(transport: UInt32?, dataSource: String?) -> Bool {
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        let source = (dataSource ?? "").lowercased()
        return !(source.contains("headphone") || source.contains("наушник"))
    }

    public static func likelySpeakers() -> Bool {
        guard let device = defaultDevice() else { return false }
        return isLikelySpeakers(transport: transportType(device), dataSource: dataSourceName(device))
    }
}

/// Слушатель смены устройства вывода по умолчанию; блок — на главном потоке.
public final class OutputDeviceWatch {
    private let onChange: () -> Void
    private var listener: AudioObjectPropertyListenerBlock?

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    public func start() {
        guard listener == nil else { return }
        let onChange = self.onChange
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var address = Self.address
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if status == noErr { listener = block }
    }

    public func stop() {
        guard let block = listener else { return }
        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        listener = nil
    }
}
