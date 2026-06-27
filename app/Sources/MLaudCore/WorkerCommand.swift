import Foundation

/// Строит команду запуска Python-worker'а (`python -m mlaud_worker`) с выбранной папкой inbox.
/// Сам процесс запускается в UI-слое; здесь — тестируемое построение аргументов и окружения.
public struct WorkerCommand {
    public let pythonExecutable: URL
    /// Каталог, из которого `mlaud_worker` импортируется (репозиторный `worker/`).
    public let workerDirectory: URL
    public let inboxFolder: URL
    /// Доп. каталоги для PYTHONPATH (например, вложенный в .app site-packages).
    public var additionalPythonPath: [URL]
    public var extraEnvironment: [String: String]

    public init(
        pythonExecutable: URL,
        workerDirectory: URL,
        inboxFolder: URL,
        additionalPythonPath: [URL] = [],
        extraEnvironment: [String: String] = [:]
    ) {
        self.pythonExecutable = pythonExecutable
        self.workerDirectory = workerDirectory
        self.inboxFolder = inboxFolder
        self.additionalPythonPath = additionalPythonPath
        self.extraEnvironment = extraEnvironment
    }

    public func arguments() -> [String] {
        ["-m", "mlaud_worker"]
    }

    /// Окружение для процесса: выбранная папка как MLAUD_INBOX + PYTHONPATH + доп. переменные.
    public func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["MLAUD_INBOX"] = inboxFolder.path
        env["PYTHONPATH"] = ([workerDirectory] + additionalPythonPath)
            .map { $0.path }.joined(separator: ":")
        for (key, value) in extraEnvironment {
            env[key] = value
        }
        return env
    }

    /// Готовый к запуску Process.
    public func makeProcess() -> Process {
        let process = Process()
        process.executableURL = pythonExecutable
        process.arguments = arguments()
        process.environment = environment()
        process.currentDirectoryURL = workerDirectory
        return process
    }
}
