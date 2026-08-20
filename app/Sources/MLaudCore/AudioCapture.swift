import AVFoundation

/// Захват микрофона сразу в том виде, который ест модель: 16 кГц, mono, int16.
/// Пересчёт делает AVAudioConverter — частота железа (48 кГц у встроенного микрофона,
/// 24 кГц у Bluetooth-гарнитуры) заранее неизвестна и меняется на ходу.
///
/// **Ничего связанного с движком не делается в главном потоке.** Обращение к
/// `inputNode` уходит синхронным запросом в coreaudiod, и на переключении Bluetooth
/// этот запрос может повиснуть надолго: приложение вставало целиком — ни меню, ни
/// горячей клавиши, потому что и то и другое обслуживает главный цикл событий.
/// Поэтому весь движок живёт на своей последовательной очереди, а наружу отдаются
/// только готовые данные и события.
public final class AudioCapture {
    public enum CaptureError: Error, LocalizedError {
        case microphoneUnavailable
        case converterUnavailable
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .microphoneUnavailable: return "микрофон недоступен"
            case .converterUnavailable:  return "не удалось создать конвертер формата"
            case .engineFailed(let m):   return "аудиодвижок не запустился: \(m)"
            }
        }
    }

    private let queue = DispatchQueue(label: "mlaud.audio.engine")
    private let target: AVAudioFormat
    private let onChunk: (Data) -> Void

    // Всё ниже — только с очереди `queue`.
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?

    // Показания для сторожа: пишет поток рендера, читает главный. Под замком, и
    // намеренно НЕ через queue.sync — очередь может стоять в coreaudiod, и
    // синхронное ожидание с главного потока вернуло бы ровно то зависание.
    private let lock = NSLock()
    private var _lastBufferAt: Date?
    private var _startedAt: Date?
    private var _deliveredFrames = 0
    private var _isRunning = false

    /// Захват пересобран после смены устройства — текст для журнала.
    public var onReconfigured: ((String) -> Void)?
    /// Пересобрать не удалось: звука больше не будет.
    public var onFailure: ((String) -> Void)?

    public init(onChunk: @escaping (Data) -> Void) {
        self.onChunk = onChunk
        self.target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                    channels: 1, interleaved: true)!
    }

    // MARK: - Наблюдаемое состояние

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    /// Время последнего буфера. Движок умеет остановиться так, что объект цел,
    /// а данные не идут.
    public var lastBufferAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastBufferAt
    }

    /// Доля реального времени, которую покрывает пришедший звук. 1.0 — норма.
    /// nil, пока данных мало для суждения.
    ///
    /// Одной живости тапа мало: после смены устройства тап оставался настроен под
    /// прежнюю частоту и отдавал шестую часть реального времени — «звук идёт», а
    /// распознавать нечего.
    public var throughput: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let startedAt = _startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 2 else { return nil }
        return Double(_deliveredFrames) / target.sampleRate / elapsed
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

    /// Запустить. Ответ приходит в главный поток: nil — получилось.
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

    /// Пересобрать по требованию — когда сторож увидел, что звук негоден.
    public func restart(completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownOnQueue(clearCounters: false)
            self.engine = AVAudioEngine()
            do {
                try self.startOnQueue()
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
        let input = engine.inputNode          // синхронный запрос в coreaudiod
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.microphoneUnavailable
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw CaptureError.converterUnavailable
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error.localizedDescription)
        }

        lock.lock()
        _lastBufferAt = Date()
        _startedAt = Date()
        _deliveredFrames = 0
        _isRunning = true
        lock.unlock()

        observeConfigurationChanges()
    }

    private func teardownOnQueue(clearCounters: Bool) {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter?.reset()
        converter = nil

        lock.lock()
        _isRunning = false
        if clearCounters {
            _lastBufferAt = nil
            _startedAt = nil
            _deliveredFrames = 0
        }
        lock.unlock()
    }

    /// Смена аудиоустройства или его формата останавливает движок и глушит тап.
    private func observeConfigurationChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // Уведомление приходит в момент переключения, а не после: система ещё не
            // устаканила устройство, и формат в этот миг читается прежний.
            self.queue.asyncAfter(deadline: .now() + 0.4) { self.reconfigureOnQueue() }
        }
    }

    private func reconfigureOnQueue() {
        guard isRunning else { return }
        let was = Int(engine.inputNode.outputFormat(forBus: 0).sampleRate)
        teardownOnQueue(clearCounters: false)
        // Прежний движок кеширует формат входа и после смены устройства продолжает
        // называть старую частоту — переустановки тапа мало, нужен новый движок.
        engine = AVAudioEngine()
        do {
            try startOnQueue()
            let now = Int(engine.inputNode.outputFormat(forBus: 0).sampleRate)
            DispatchQueue.main.async {
                self.onReconfigured?("аудиоустройство сменилось (\(was) → \(now) Гц), захват пересобран")
            }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { self.onFailure?(message) }
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }

        lock.lock()
        _lastBufferAt = Date()
        _deliveredFrames += Int(out.frameLength)
        lock.unlock()

        onChunk(Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size))
    }

    deinit {
        // Движок захватываем явно: self к этому моменту уже разрушается.
        let engine = self.engine
        let observer = configObserver
        queue.async {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
