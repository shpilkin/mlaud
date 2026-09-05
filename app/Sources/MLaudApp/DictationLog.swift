import Foundation

/// Журнал диктовки — рядом с логом worker'а, по той же причине: без него ошибки
/// невидимы. Горячая клавиша либо зарегистрировалась, либо нет; сработала либо нет —
/// по поведению приложения этого не понять, а спрашивать пользователя «а точно нажал?»
/// бессмысленно.
enum DictationLog {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ASR/service/dictation.log")
    }

    private static let queue = DispatchQueue(label: "mlaud.dictation.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Последние `count` строк журнала для экрана; нет файла — пусто.
    static func tail(_ count: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(count))
    }

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            let fm = FileManager.default
            let url = Self.url
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
