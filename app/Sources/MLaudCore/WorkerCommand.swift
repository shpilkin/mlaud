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
    /// Запускаемый модуль. Пакетная обработка — `mlaud_worker`, диктовка —
    /// `mlaud_worker.dictate` (резидентный процесс с загруженной моделью).
    public var module: String

    public init(
        pythonExecutable: URL,
        workerDirectory: URL,
        inboxFolder: URL,
        additionalPythonPath: [URL] = [],
        extraEnvironment: [String: String] = [:],
        module: String = "mlaud_worker"
    ) {
        self.pythonExecutable = pythonExecutable
        self.workerDirectory = workerDirectory
        self.inboxFolder = inboxFolder
        self.additionalPythonPath = additionalPythonPath
        self.extraEnvironment = extraEnvironment
        self.module = module
    }

    public func arguments() -> [String] {
        ["-m", module]
    }

    /// Каталог для кешей, которые Python и numba иначе пишут рядом с исходниками.
    public static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MLaud")
    }

    /// Окружение для процесса: выбранная папка как MLAUD_INBOX + PYTHONPATH + доп. переменные.
    public func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["MLAUD_INBOX"] = inboxFolder.path
        env["PYTHONPATH"] = ([workerDirectory] + additionalPythonPath)
            .map { $0.path }.joined(separator: ":")
        // Ничего не писать внутрь .app. Python кладёт __pycache__ рядом с исходниками, а
        // numba (через librosa у pyannote) — свой кеш .nbi/.nbc туда же. Оба каталога
        // оказываются внутри бандла и ломают печать целостности подписи, а от неё зависит,
        // считает ли система приложение тем самым — то есть выданные разрешения.
        // Не отключаем кеш, а уводим: с PYTHONDONTWRITEBYTECODE каждый запуск
        // перекомпилировал бы всё дерево зависимостей заново.
        env["PYTHONPYCACHEPREFIX"] = Self.cacheDirectory.appendingPathComponent("pycache").path
        env["NUMBA_CACHE_DIR"] = Self.cacheDirectory.appendingPathComponent("numba").path
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
