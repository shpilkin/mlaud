import Foundation
import MLaudCore

/// Процесс MCP-сервера для внешних агентов (`python -m mlaud_worker.mcp --http`).
///
/// Сервер живёт, пока включена настройка и работает приложение: stdin процесса — труба
/// приложения, её закрытие (выход или крах MLaud) завершает сервер и освобождает порт.
/// Модели сервер грузит и выгружает сам, по вызовам и простою.
final class AgentAccessController {
    private(set) var state: AgentAccess.State = .disabled
    var onStateChanged: (() -> Void)?

    private let logURL: URL
    private var makeCommand: (() -> WorkerCommand)?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var generation = 0
    private var lastError: String?
    private var failures: [Date] = []
    private var restartWork: DispatchWorkItem?

    init(logURL: URL) {
        self.logURL = logURL
    }

    deinit { stop() }

    func start(makeCommand: @escaping () -> WorkerCommand) {
        stop()
        self.makeCommand = makeCommand
        failures = []
        launch()
    }

    func stop() {
        restartWork?.cancel()
        restartWork = nil
        makeCommand = nil
        generation += 1
        if let process, process.isRunning {
            // EOF на stdin — штатный выход сервера; terminate — если не вышел сам.
            try? stdinPipe?.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { process.terminate() }
            }
        }
        process = nil
        stdinPipe = nil
        set(.disabled)
    }

    func fail(_ reason: String) {
        stop()
        set(.failed(reason))
    }

    private func set(_ new: AgentAccess.State) {
        guard new != state else { return }
        state = new
        onStateChanged?()
    }

    private func launch() {
        guard let makeCommand else { return }
        let process = makeCommand().makeProcess()
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = openLog()

        generation += 1
        let gen = generation
        lastError = nil
        var buffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let events = buffer.append(data).compactMap(AgentAccess.Event.parse)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { self?.handle(events, generation: gen) }
        }
        process.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async { self?.handleExit(code: code, generation: gen) }
        }

        do {
            try process.run()
        } catch {
            set(.failed("не удалось запустить python: \(error.localizedDescription)"))
            return
        }
        self.process = process
        self.stdinPipe = stdin
        set(.starting)
    }

    private func handle(_ events: [AgentAccess.Event], generation gen: Int) {
        guard gen == generation else { return }
        for event in events {
            switch event {
            case .ready(let port): set(.listening(port: port))  // и повторно, после перезапуска себя
            case .error(let message): lastError = message
            }
        }
    }

    private func handleExit(code: Int32, generation gen: Int) {
        guard gen == generation, makeCommand != nil else { return }
        process = nil
        stdinPipe = nil
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < 60 } + [now]
        switch AgentAccess.afterExit(code: code, lastError: lastError,
                                     failuresInLastMinute: failures.count) {
        case .fail(let reason):
            set(.failed(reason))
        case .restart(let delay):
            set(.starting)
            let work = DispatchWorkItem { [weak self] in self?.launch() }
            restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// stderr сервера — в журнал; при каждом запуске журнал обрезается, если вырос.
    private func openLog() -> FileHandle {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        if size > 2_000_000 || !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return .nullDevice }
        handle.seekToEndOfFile()
        return handle
    }
}
