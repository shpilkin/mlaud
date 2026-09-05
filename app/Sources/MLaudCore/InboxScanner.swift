import Foundation

/// Поддерживаемые расширения аудио (зеркало DEFAULT_AUDIO_EXTS в Python-worker'е).
public enum AudioExtensions {
    public static let `default`: Set<String> = ["m4a", "mp3", "wav", "aac", "aiff", "caf"]
}

/// Сканирует папку inbox и возвращает готовые к обработке аудиофайлы.
/// Логика «готовности» совпадает с worker'ом: пропускаем скрытые, iCloud-плейсхолдеры,
/// пустые и не-аудио файлы.
public struct InboxScanner {
    public let audioExtensions: Set<String>

    public init(audioExtensions: Set<String> = AudioExtensions.default) {
        self.audioExtensions = audioExtensions
    }

    /// Проверка готовности одного файла.
    ///
    /// Отдельная ловушка iCloud: при «Оптимизации хранилища» файл может быть *выгружен* —
    /// у него настоящее имя и размер, но локальных данных нет (status != .current).
    /// Такой файл нельзя отдавать worker'у (чтение упадёт) — его надо сперва докачать.
    public func isReady(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return false }            // скрытый
        if name.hasSuffix(".icloud") { return false }      // недокачанный плейсхолдер iCloud
        guard audioExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values?.isRegularFile == true else { return false }
        guard (values?.fileSize ?? 0) > 0 else { return false }
        // Невыгруженный iCloud-файл: запускаем докачку и считаем «ещё не готовым».
        if values?.isUbiquitousItem == true,
           let status = values?.ubiquitousItemDownloadingStatus,
           status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return false
        }
        return true
    }

    /// Аудио, которое ещё едет из iCloud: плейсхолдеры `.icloud` и выгруженные файлы.
    /// Для экрана: «N докачиваются» — иначе непонятно, почему очередь пуста, а файл есть.
    public func downloadingAudioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
            options: []
        ) else { return [] }
        return items.filter { url in
            var name = url.lastPathComponent
            if name.hasSuffix(".icloud") {
                // «.имя.m4a.icloud» — плейсхолдер невыгруженного файла.
                name = String(name.dropLast(".icloud".count))
                if name.hasPrefix(".") { name.removeFirst() }
                return audioExtensions.contains((name as NSString).pathExtension.lowercased())
            }
            guard !name.hasPrefix("."),
                  audioExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [
                    .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                  values.isUbiquitousItem == true,
                  let status = values.ubiquitousItemDownloadingStatus
            else { return false }
            return status != .current
        }
    }

    /// Готовые аудиофайлы в папке, отсортированные по имени.
    public func readyAudioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [
                .isRegularFileKey, .fileSizeKey,
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            ],
            options: []
        ) else {
            return []
        }
        return items
            .filter { isReady($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
