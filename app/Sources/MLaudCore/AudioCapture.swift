import AVFoundation
import CoreAudio

/// Захват микрофона сразу в том виде, который ест модель: 16 кГц, mono, int16.
///
/// На AVCaptureSession, а не на AVAudioEngine, и это не вкусовщина — измерено на живых
/// AirPods Pro в один и тот же момент, при устройстве в состоянии 24 кГц:
///
///     AVCaptureSession  → видит 24000 Гц, 60480 сэмплов за 2.5 с (100%)
///     AVAudioEngine     → видит 48000 Гц, 0 кадров
///
/// У Bluetooth-гарнитуры вход живёт на своей частоте, а AVAudioEngine упорно берёт
/// частоту вывода: запускается «успешно» и отдаёт тишину. На встроенном микрофоне
/// вход и вывод совпадают, поэтому там расхождение и не проявлялось.
///
/// Заодно исчез целый слой: формат запрашивается у системы (`audioSettings`), поэтому
/// ни угадывания частоты, ни конвертера, ни пересборок под сменившийся формат больше нет.
///
/// Сессия живёт на своей очереди: `startRunning()` ходит в аудиодемон и умеет думать
/// секундами, а в главном потоке это вешает меню и горячую клавишу.
public final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    public enum CaptureError: Error, LocalizedError {
        case microphoneUnavailable
        case sessionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .microphoneUnavailable: return "микрофон недоступен"
            case .sessionFailed(let m):  return "не удалось начать запись: \(m)"
            }
        }
    }

    public static let sampleRate: Double = 16000

    private let queue = DispatchQueue(label: "mlaud.audio.session")
    private let sampleQueue = DispatchQueue(label: "mlaud.audio.samples")
    private let onChunk: (Data) -> Void

    // Только с очереди `queue`.
    private var session: AVCaptureSession?
    private var installedDeviceID: String?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var lastRebuildAt: Date?
    private var rebuildsInBurst = 0

    // Показания сторожа: пишет поток захвата, читает главный. Под замком и намеренно
    // НЕ через queue.sync — очередь может стоять в аудиодемоне, и синхронное ожидание
    // с главного потока вернуло бы зависание всего приложения.
    private let lock = NSLock()
    private var _lastBufferAt: Date?
    private var _startedAt: Date?
    private var _deliveredFrames = 0
    private var _isRunning = false

    /// Что происходит с устройством — для журнала.
    public var onDiagnostic: ((String) -> Void)?
    /// Захват пересобран после смены устройства.
    public var onReconfigured: ((String) -> Void)?
    /// Пересобрать не удалось: звука больше не будет.
    public var onFailure: ((String) -> Void)?

    public init(onChunk: @escaping (Data) -> Void) {
        self.onChunk = onChunk
        super.init()
    }

    // MARK: - Наблюдаемое состояние

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    public var lastBufferAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastBufferAt
    }

    /// Доля реального времени, которую покрывает пришедший звук. 1.0 — норма.
    /// nil, пока данных мало для суждения.
    public var throughput: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let startedAt = _startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 2 else { return nil }
        return Double(_deliveredFrames) / Self.sampleRate / elapsed
    }

    /// Режим микрофона macOS для приложения («Стандартный» / «Изоляция голоса» / …).
    /// «Изоляция» глушит паузы и соседние голоса — до 65 % окна нулями — и живая
    /// пометка «Я / не я» на таком тракте не работает (poc/livespk/RESULT.md).
    /// Вызывается с главного потока (завершение `start` приходит туда).
    nonisolated public static func currentMicrophoneMode() -> String? {
        MainActor.assumeIsolated {
            AVCaptureDevice.activeMicrophoneMode.apiName
        }
    }

    /// Разрешение на микрофон. Спрашивается один раз, дальше отвечает система.
    public static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    // MARK: - Управление

    public func start(completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.startOnQueue()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.teardownOnQueue(clearCounters: true) }
    }

    /// Пересобрать по требованию — когда сторож увидел, что звука нет.
    public func restart(completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownOnQueue(clearCounters: false)
            do {
                try self.startOnQueue()
                self.lastRebuildAt = Date()
                DispatchQueue.main.async { completion?(true) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.onFailure?(message)
                    completion?(false)
                }
            }
        }
    }

    // MARK: - Внутреннее, только с очереди

    private func startOnQueue() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.microphoneUnavailable
        }
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.sessionFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            throw CaptureError.sessionFailed("устройство «\(device.localizedName)» не добавляется")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Формат просим у системы, а не пересчитываем сами: ровно то, что ест модель.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            throw CaptureError.sessionFailed("выход не добавляется")
        }
        session.addOutput(output)

        session.startRunning()
        guard session.isRunning else {
            throw CaptureError.sessionFailed("сессия не запустилась")
        }

        self.session = session
        installedDeviceID = device.uniqueID

        lock.lock()
        _lastBufferAt = Date()
        _startedAt = Date()
        _deliveredFrames = 0
        _isRunning = true
        lock.unlock()

        let name = device.localizedName
        DispatchQueue.main.async {
            self.onDiagnostic?("вход: \(name), \(Int(Self.sampleRate)) Гц, каналов 1")
        }
        observeDefaultInputChanges()
    }

    private func teardownOnQueue(clearCounters: Bool) {
        removeDefaultInputListener()
        if let session {
            session.stopRunning()
            for output in session.outputs {
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
        }
        session = nil

        lock.lock()
        _isRunning = false
        if clearCounters {
            _lastBufferAt = nil
            _startedAt = nil
            _deliveredFrames = 0
        }
        lock.unlock()
    }

    /// Слушаем смену устройства ввода по умолчанию: сессия за системным выбором
    /// сама не переезжает, её надо пересобрать под новое устройство.
    private func observeDefaultInputChanges() {
        guard deviceListener == nil else { return }
        var address = Self.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Устройство переключается не мгновенно; даём ему устояться.
            self.queue.asyncAfter(deadline: .now() + 0.4) { self.reconfigureOnQueue() }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
            deviceListener = block
        }
    }

    private func removeDefaultInputListener() {
        guard let deviceListener else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
        self.deviceListener = nil
    }

    private func reconfigureOnQueue() {
        guard isRunning else { return }
        let current = AVCaptureDevice.default(for: .audio)
        let changed = current?.uniqueID != installedDeviceID
        let since = lastRebuildAt.map { Date().timeIntervalSince($0) }

        switch RebuildPolicy.decide(changed: changed, sinceLastRebuild: since,
                                    rebuildsInBurst: rebuildsInBurst) {
        case .unchanged, .cooldown:
            return
        case .tooManyRebuilds:
            DispatchQueue.main.async {
                self.onReconfigured?("устройство не устаканивается — перестаю пересобирать, "
                                     + "дальше решает сторож по объёму звука")
            }
            return
        case .rebuild:
            break
        }
        if let since, since > RebuildPolicy.burstWindow { rebuildsInBurst = 0 }
        rebuildsInBurst += 1

        let wasName = installedDeviceID
        teardownOnQueue(clearCounters: false)
        do {
            try startOnQueue()
            lastRebuildAt = Date()
            let now = AVCaptureDevice.default(for: .audio)?.localizedName ?? "?"
            DispatchQueue.main.async {
                self.onReconfigured?("устройство ввода сменилось (было \(wasName ?? "?")) "
                                     + "— пересобрал на «\(now)»")
            }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { self.onFailure?(message) }
        }
    }

    // MARK: - Приём звука

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr,
              let pointer, length > 0 else { return }
        let data = Data(bytes: pointer, count: length)

        lock.lock()
        _lastBufferAt = Date()
        _deliveredFrames += length / MemoryLayout<Int16>.size
        lock.unlock()

        onChunk(data)
    }

    // MARK: - Опрос устройств

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Текущее устройство ввода по умолчанию.
    public static func defaultInputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    public static func deviceName(_ device: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        return status == noErr ? (name as String) : "устройство \(device)"
    }

    /// Частота устройства по мнению CoreAudio.
    public static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    deinit {
        removeDefaultInputListener()
        let session = self.session
        queue.async { session?.stopRunning() }
    }
}

/// Решение «пересобирать ли захват» — вынесено отдельно, потому что на живом железе
/// его не проверить, а ошибка стоит дорого: одна редакция этой логики уже дала
/// замкнутый круг пересборок раз в две секунды.
public enum RebuildDecision: Equatable {
    case rebuild
    /// Устройство то же — трогать нечего.
    case unchanged
    /// Отголосок собственной пересборки: она останавливает запись, Bluetooth-гарнитура
    /// уходит обратно в музыкальный профиль, и приходит очередное уведомление.
    case cooldown
    /// Устройство мечется — перестаём дёргаться.
    case tooManyRebuilds
}

public enum RebuildPolicy {
    public static let cooldown: TimeInterval = 3
    public static let maxRebuildsInBurst = 3
    /// После такой паузы серия считается законченной и счётчик обнуляется.
    public static let burstWindow: TimeInterval = 30

    public static func decide(changed: Bool,
                              sinceLastRebuild: TimeInterval?,
                              rebuildsInBurst: Int) -> RebuildDecision {
        if !changed { return .unchanged }
        if let sinceLastRebuild, sinceLastRebuild < cooldown { return .cooldown }
        let effective = (sinceLastRebuild ?? .infinity) > burstWindow ? 0 : rebuildsInBurst
        if effective >= maxRebuildsInBurst { return .tooManyRebuilds }
        return .rebuild
    }
}

extension AVCaptureDevice.MicrophoneMode {
    /// Имя для журнала и снимка; nil — незнакомый режим свежей macOS.
    var apiName: String? {
        switch self {
        case .standard: return "standard"
        case .voiceIsolation: return "voiceIsolation"
        case .wideSpectrum: return "wideSpectrum"
        @unknown default: return nil
        }
    }
}
