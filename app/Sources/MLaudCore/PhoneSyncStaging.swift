import Foundation

/// Промежуточная папка приёма: `<inbox>/.incoming/<id>.part`.
///
/// Недокачанный кусок остаётся на диске намеренно — телефон дошлёт его с того же
/// места. Но идентификатор куска считается по содержимому записи: подрезал запись
/// на телефоне — id сменился, и прежний кусок не нужен уже никому. Сам он не
/// исчезнет: сервер трогает только те куски, за которыми пришли. Поэтому метём
/// по возрасту.
public enum PhoneSyncStaging {
    public static let partExtension = "part"

    /// Сколько ждём докачку, прежде чем считать кусок брошенным. Неделя — с запасом
    /// на «телефон уехал в отпуск»: цена ошибки всего лишь перекачка с нуля.
    public static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Удаляет недокачанные куски старше `maxAge`. Возвращает удалённое.
    @discardableResult
    public static func sweep(
        directory: URL, maxAge: TimeInterval = defaultMaxAge, now: Date = Date()
    ) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var removed: [URL] = []
        for url in entries where url.pathExtension == partExtension {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > maxAge else { continue }
            do {
                try fm.removeItem(at: url)
                removed.append(url)
            } catch {
                continue
            }
        }
        return removed
    }
}
