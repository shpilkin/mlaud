import Foundation
import MLaudCore

/// Запуск `python -m mlaud_worker.voices <подкоманда>` из окна «Голоса».
///
/// Приложение сайдкары и базу голосов только читает; любое изменение — через worker,
/// чтобы у файлов был один писатель (ADR-017). Вывод собираем целиком: команды
/// короткие, а stderr нужен для сообщения об ошибке.
struct VoicesRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
        /// Что показать человеку при ошибке: stderr, иначе stdout, иначе код.
        var message: String {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty { return err }
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? "код возврата \(status)" : out
        }
    }

    let makeCommand: ([String]) -> WorkerCommand
    let log: (String) -> Void

    func run(_ args: [String], completion: @escaping (Result) -> Void) {
        let command = makeCommand(args)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = command.makeProcess()
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let result: Result
            do {
                try process.run()
                // Читать до waitUntilExit: иначе полный пайп подвесит процесс.
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result = Result(status: process.terminationStatus,
                                stdout: String(decoding: outData, as: UTF8.self),
                                stderr: String(decoding: errData, as: UTF8.self))
            } catch {
                result = Result(status: -1, stdout: "", stderr: error.localizedDescription)
            }
            log("voices \(args.joined(separator: " ")) → \(result.status)"
                + (result.stderr.isEmpty ? "" : "\n" + result.stderr))
            DispatchQueue.main.async { completion(result) }
        }
    }
}
