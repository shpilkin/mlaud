import Foundation

/// Кусок звука от захвата: float32, interleaved (L R L R …), `channels` каналов.
struct AudioChunk {
    let samples: [Float]
    let channels: Int
    let sampleRate: Double
}

/// Одна ветка захвата звука приложения. `start` возвращает, когда данные пошли (или
/// готовы пойти); всё, что стоит записать в журнал (формат, устройство, ошибки потока),
/// уходит в `onEvent` одной строкой без перевода строки.
protocol Capturer: AnyObject {
    /// Формат после старта: "float32 48000 Hz 2ch non-interleaved" и т.п.
    var formatDescription: String { get }
    func start(onChunk: @escaping (AudioChunk) -> Void,
               onEvent: @escaping (String) -> Void) async throws
    func stop()
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// Целевое приложение: PID плюс, если известно, имя и bundle id.
struct Target {
    let pid: pid_t
    let name: String
    let bundleID: String?
}

/// Параметры ветки из командной строки.
struct CaptureOptions {
    /// Моно-микс вместо стерео.
    var mono = false
    /// Контроль: захватывать всё (глобальный tap / весь дисплей), а не одно приложение.
    var all = false
    /// tap: агрегатное устройство без поддевайса вывода — только tap.
    var tapOnlyAggregate = false
    /// sck: запрошенная частота (8000/16000/24000/48000).
    var rate = 48000
}
