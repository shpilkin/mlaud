import CoreAudio
import Foundation

/// Устройство вывода по умолчанию: имя и UID сейчас, события смены.
enum DeviceWatch {
    static func defaultOutputDevice() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { return "?" }
        return value.takeRetainedValue() as String
    }

    static func describe(_ device: AudioObjectID) -> String {
        "\(string(device, kAudioObjectPropertyName)) uid=\(string(device, kAudioDevicePropertyDeviceUID)) id=\(device)"
    }

    static func nominalRate(_ device: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        return rate
    }

    /// Слушатель смены устройства вывода по умолчанию; блок получает описание нового.
    static func watchDefaultOutput(_ onChange: @escaping (String) -> Void) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            onChange(describe(defaultOutputDevice()))
        }
    }
}
