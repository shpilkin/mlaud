import Foundation

/// Следит за изменениями содержимого папки (добавление/удаление файлов) и вызывает onChange.
/// Реализация на DispatchSource (vnode) — реагирует мгновенно, без опроса.
public final class FolderWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    public init(url: URL,
                queue: DispatchQueue = DispatchQueue(label: "mlaud.folderwatcher"),
                onChange: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
    }

    /// Начать слежение. Возвращает true, если папку удалось открыть.
    @discardableResult
    public func start() -> Bool {
        stop()
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return false }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.onChange()
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        source = src
        src.resume()
        return true
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    public var isWatching: Bool { source != nil }

    deinit { stop() }
}
