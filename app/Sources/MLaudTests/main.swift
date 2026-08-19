import AppKit
import Carbon.HIToolbox
import Foundation
import MLaudCore

// Минимальный тест-раннер без XCTest (XCTest нет в Command Line Tools).
// Запуск: swift run MLaudTests. Возвращает код 1 при наличии падений.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ message: String,
           file: StaticString = #file, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("  FAIL: \(message)  (\(file):\(line))")
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ message: String,
                      file: StaticString = #file, line: UInt = #line) {
    check(a == b, "\(message) — ожидали \(b), получили \(a)", file: file, line: line)
}

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("• \(name)")
    } catch {
        failed += 1
        print("  FAIL (threw): \(name): \(error)")
    }
}

// MARK: helpers

func makeDefaults() -> UserDefaults {
    let suite = "mlaud.test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func writeFile(_ dir: URL, _ name: String, bytes: Int = 4) throws {
    try Data(repeating: 0x61, count: bytes)
        .write(to: dir.appendingPathComponent(name))
}

// MARK: FolderStore

test("FolderStore: изначально папки нет") {
    let store = FolderStore(defaults: makeDefaults())
    check(store.inboxFolder == nil, "inboxFolder должен быть nil")
    check(!store.hasInboxFolder, "hasInboxFolder должен быть false")
}

test("FolderStore: запись и чтение сохраняются") {
    let defaults = makeDefaults()
    let store = FolderStore(defaults: defaults)
    store.inboxFolder = URL(fileURLWithPath: "/tmp/mlaud-inbox", isDirectory: true)
    check(store.hasInboxFolder, "hasInboxFolder должен быть true")
    eq(store.inboxFolder?.path, "/tmp/mlaud-inbox", "путь сохранён")
    eq(FolderStore(defaults: defaults).inboxFolder?.path, "/tmp/mlaud-inbox", "новый экземпляр читает то же")
}

test("FolderStore: очистка") {
    let store = FolderStore(defaults: makeDefaults())
    store.inboxFolder = URL(fileURLWithPath: "/tmp/x")
    store.inboxFolder = nil
    check(store.inboxFolder == nil, "после nil должно очиститься")
}

// MARK: InboxScanner

test("InboxScanner: фильтрация и сортировка") {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeFile(dir, "b.m4a")
    try writeFile(dir, "a.m4a")
    try writeFile(dir, "note.txt")
    try writeFile(dir, "c.m4a.icloud")
    try writeFile(dir, ".hidden.m4a")
    try writeFile(dir, "empty.m4a", bytes: 0)
    let names = InboxScanner().readyAudioFiles(in: dir).map { $0.lastPathComponent }
    eq(names, ["a.m4a", "b.m4a"], "только готовые аудио, отсортированы")
}

test("InboxScanner: разные аудио-расширения") {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeFile(dir, "rec.mp3")
    try writeFile(dir, "rec.wav")
    try writeFile(dir, "rec.aac")
    let exts = Set(InboxScanner().readyAudioFiles(in: dir).map { $0.pathExtension })
    eq(exts, Set(["mp3", "wav", "aac"]), "все аудио-расширения приняты")
}

test("InboxScanner: isReady проверки") {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeFile(dir, "ok.m4a")
    let s = InboxScanner()
    check(s.isReady(dir.appendingPathComponent("ok.m4a")), "ok.m4a готов")
    check(!s.isReady(dir.appendingPathComponent(".ok.m4a")), "скрытый не готов")
    check(!s.isReady(dir.appendingPathComponent("ok.m4a.icloud")), "плейсхолдер не готов")
    check(!s.isReady(dir.appendingPathComponent("missing.m4a")), "отсутствующий не готов")
}

test("InboxScanner: пустая папка") {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    check(InboxScanner().readyAudioFiles(in: dir).isEmpty, "пусто")
}

// MARK: WorkerCommand

test("WorkerCommand: аргументы запускают модуль") {
    let cmd = WorkerCommand(
        pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
        workerDirectory: URL(fileURLWithPath: "/repo/worker"),
        inboxFolder: URL(fileURLWithPath: "/inbox"))
    eq(cmd.arguments(), ["-m", "mlaud_worker"], "аргументы")
}

test("WorkerCommand: окружение содержит выбранную папку") {
    let cmd = WorkerCommand(
        pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
        workerDirectory: URL(fileURLWithPath: "/repo/worker"),
        inboxFolder: URL(fileURLWithPath: "/my/inbox"),
        extraEnvironment: ["MLAUD_MODEL": "rnnt"])
    let env = cmd.environment(base: ["EXISTING": "1"])
    eq(env["MLAUD_INBOX"], "/my/inbox", "MLAUD_INBOX = выбранная папка")
    eq(env["PYTHONPATH"], "/repo/worker", "PYTHONPATH")
    eq(env["MLAUD_MODEL"], "rnnt", "доп. переменная")
    eq(env["EXISTING"], "1", "базовое окружение сохранено")
}

test("WorkerCommand: additionalPythonPath добавляется в PYTHONPATH") {
    let cmd = WorkerCommand(
        pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
        workerDirectory: URL(fileURLWithPath: "/app/worker"),
        inboxFolder: URL(fileURLWithPath: "/inbox"),
        additionalPythonPath: [URL(fileURLWithPath: "/app/site-packages")])
    let env = cmd.environment(base: [:])
    eq(env["PYTHONPATH"], "/app/worker:/app/site-packages", "worker + site-packages в PYTHONPATH")
}

test("WorkerCommand: makeProcess настроен") {
    let cmd = WorkerCommand(
        pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
        workerDirectory: URL(fileURLWithPath: "/repo/worker"),
        inboxFolder: URL(fileURLWithPath: "/inbox"))
    let p = cmd.makeProcess()
    eq(p.executableURL?.path, "/usr/bin/python3", "executable")
    eq(p.arguments ?? [], ["-m", "mlaud_worker"], "arguments")
    eq(p.currentDirectoryURL?.path, "/repo/worker", "cwd")
    eq(p.environment?["MLAUD_INBOX"], "/inbox", "env inbox")
}

// MARK: ProcessingStatus

test("ProcessingStatus: заголовки") {
    eq(ProcessingStatus.noFolder.menuTitle, "Папка не выбрана", "noFolder")
    eq(ProcessingStatus.processing(current: 1, total: 3).menuTitle, "Транскрибирую 1 из 3…", "processing")
    eq(ProcessingStatus.done(count: 2).menuTitle, "Готово: обработано 2", "done")
    eq(ProcessingStatus.error("x").menuTitle, "Ошибка: x", "error")
}

// MARK: SettingsStore

test("SettingsStore: значения по умолчанию") {
    let s = SettingsStore(defaults: makeDefaults())
    eq(s.modelType, "rnnt", "модель по умолчанию rnnt")
    check(s.instantWatch, "мгновенная обработка включена по умолчанию")
    check(s.notificationsEnabled, "уведомления включены по умолчанию")
    eq(s.telegramToken, "", "токен пуст")
}

test("SettingsStore: запись и чтение сохраняются") {
    let defaults = makeDefaults()
    let s = SettingsStore(defaults: defaults)
    s.telegramToken = "tok"
    s.telegramChatID = "123"
    s.modelType = "ctc"
    s.instantWatch = false
    s.notificationsEnabled = false
    let s2 = SettingsStore(defaults: defaults)
    eq(s2.telegramToken, "tok", "токен")
    eq(s2.telegramChatID, "123", "chat_id")
    eq(s2.modelType, "ctc", "модель")
    check(!s2.instantWatch, "instantWatch выключен")
    check(!s2.notificationsEnabled, "уведомления выключены")
}

test("SettingsStore: некорректная модель откатывается к дефолту") {
    let defaults = makeDefaults()
    defaults.set("garbage", forKey: SettingsStore.Key.modelType)
    eq(SettingsStore(defaults: defaults).modelType, "rnnt", "невалидная модель → rnnt")
}

test("SettingsStore: workerEnvironment без telegram-ключей при пустых полях") {
    let s = SettingsStore(defaults: makeDefaults())
    let env = s.workerEnvironment()
    eq(env["MLAUD_MODEL"], "rnnt", "модель пробрасывается")
    check(env["MLAUD_TG_TOKEN"] == nil, "пустой токен не пробрасывается")
    check(env["MLAUD_TG_CHAT_ID"] == nil, "пустой chat_id не пробрасывается")
}

test("SettingsStore: workerEnvironment с telegram-ключами (с триммингом)") {
    let s = SettingsStore(defaults: makeDefaults())
    s.telegramToken = "  tok  "
    s.telegramChatID = "123"
    let env = s.workerEnvironment()
    eq(env["MLAUD_TG_TOKEN"], "tok", "токен обрезан от пробелов")
    eq(env["MLAUD_TG_CHAT_ID"], "123", "chat_id проброшен")
}

test("SettingsStore: диаризация выключена по умолчанию, без env-ключей") {
    let s = SettingsStore(defaults: makeDefaults())
    check(!s.diarizeEnabled, "диаризация выключена по умолчанию")
    let env = s.workerEnvironment()
    check(env["MLAUD_DIARIZE"] == nil, "MLAUD_DIARIZE не задан")
    check(env["MLAUD_HF_TOKEN"] == nil, "MLAUD_HF_TOKEN не задан")
    check(env["MLAUD_NUM_SPEAKERS"] == nil, "MLAUD_NUM_SPEAKERS не задан")
}

test("SettingsStore: диаризация включена пробрасывает env") {
    let s = SettingsStore(defaults: makeDefaults())
    s.diarizeEnabled = true
    s.hfToken = "  hf_abc  "
    s.numSpeakers = 3
    let env = s.workerEnvironment()
    eq(env["MLAUD_DIARIZE"], "1", "флаг диаризации")
    eq(env["MLAUD_HF_TOKEN"], "hf_abc", "HF-токен обрезан")
    eq(env["MLAUD_NUM_SPEAKERS"], "3", "число спикеров")
    eq(env["MLAUD_DIARIZE_DEVICE"], "mps", "устройство по умолчанию mps")
}

test("SettingsStore: устройство диаризации — дефолт mps, валидация, проброс") {
    let defaults = makeDefaults()
    let s = SettingsStore(defaults: defaults)
    eq(s.diarizeDevice, "mps", "по умолчанию mps")
    s.diarizeDevice = "cpu"
    eq(SettingsStore(defaults: defaults).diarizeDevice, "cpu", "сохраняется")
    defaults.set("garbage", forKey: SettingsStore.Key.diarizeDevice)
    eq(SettingsStore(defaults: defaults).diarizeDevice, "mps", "невалидное → mps")
}

test("SettingsStore: устройство не пробрасывается без диаризации") {
    let s = SettingsStore(defaults: makeDefaults())
    s.diarizeDevice = "cpu"
    check(s.workerEnvironment()["MLAUD_DIARIZE_DEVICE"] == nil, "без диаризации устройство не нужно")
}

test("SettingsStore: numSpeakers=0 (авто) не пробрасывается") {
    let s = SettingsStore(defaults: makeDefaults())
    s.diarizeEnabled = true
    s.numSpeakers = 0
    check(s.workerEnvironment()["MLAUD_NUM_SPEAKERS"] == nil, "0 = авто, env не задаётся")
}

// MARK: FolderWatcher

test("FolderWatcher: реагирует на новый файл") {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sem = DispatchSemaphore(value: 0)
    let w = FolderWatcher(url: dir) { sem.signal() }
    check(w.start(), "watcher стартовал")
    check(w.isWatching, "isWatching == true")
    try writeFile(dir, "new.m4a")
    let fired = sem.wait(timeout: .now() + 5)
    check(fired == .success, "пришло событие об изменении папки")
    w.stop()
    check(!w.isWatching, "после stop() isWatching == false")
}

test("FolderWatcher: start на несуществующей папке возвращает false") {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let w = FolderWatcher(url: missing) { }
    check(!w.start(), "start() == false для отсутствующей папки")
    check(!w.isWatching, "не следит")
}

// MARK: - Диктовка: протокол резидентного процесса

test("DictationEvent: разбор событий") {
    check(DictationEvent.parse(line: #"{"t":"ready"}"#) == .ready, "ready")
    check(DictationEvent.parse(line: #"{"t":"commit","text":"привет"}"#) == .commit("привет"), "commit")
    check(DictationEvent.parse(line: #"{"t":"preview","text":"мир"}"#) == .preview("мир"), "preview")
    check(DictationEvent.parse(line: #"{"t":"error","message":"ой"}"#) == .error("ой"), "error")
}

test("DictationEvent: мусор в stdout игнорируется, а не роняет сессию") {
    check(DictationEvent.parse(line: "UserWarning: torchaudio deprecated") == nil, "не JSON — nil")
    check(DictationEvent.parse(line: #"{"t":"неизвестно"}"#) == nil, "чужой тип — nil")
    check(DictationEvent.parse(line: #"{"нет":"t"}"#) == nil, "без поля t — nil")
}

test("DictationCommand: строки протокола") {
    check(DictationCommand.flush.line() == #"{"t":"flush"}"#, "flush")
    check(DictationCommand.quit.line() == #"{"t":"quit"}"#, "quit")
    let audio = DictationCommand.audio(Data([0x01, 0x02])).line()
    check(audio == #"{"t":"audio","pcm":"AQI="}"#, "audio в base64")
    check(DictationCommand.flush.data().last == UInt8(ascii: "\n"), "команда заканчивается переводом строки")
}

test("LineBuffer: склеивает JSON, разрезанный пайпом пополам") {
    var buf = LineBuffer()
    check(buf.append(Data(#"{"t":"comm"#.utf8)).isEmpty, "неполная строка не отдаётся")
    let lines = buf.append(Data("it\"}\n".utf8))
    check(lines == [#"{"t":"commit"}"#], "склеилась после прихода хвоста")
}

test("LineBuffer: несколько строк в одном куске") {
    var buf = LineBuffer()
    let lines = buf.append(Data("{\"a\":1}\n{\"b\":2}\n{\"c\"".utf8))
    check(lines.count == 2, "отданы обе целые строки, огрызок придержан")
    check(buf.append(Data(":3}\n".utf8)) == [#"{"c":3}"#], "огрызок дособрался")
}

test("TextJoiner: пробелы между кусками, но не перед запятой") {
    var j = TextJoiner()
    check(j.next("Так,") == "Так,", "первый кусок без ведущего пробела")
    check(j.next("погнали.") == " погнали.", "дальше — с пробелом")
    check(j.next(",") == ",", "знак препинания приклеивается")
    check(j.next("   ") == "", "пустой кусок ничего не печатает")
}

test("TextJoiner: reset начинает новую диктовку без ведущего пробела") {
    var j = TextJoiner()
    _ = j.next("раз")
    j.reset()
    check(j.next("два") == "два", "после reset снова без пробела")
}

test("TextInserter: длинный текст режется по символам, не по UTF-16") {
    let parts = TextInserter.split("привет мир как дела друг", limit: 8)
    check(parts.joined() == "привет мир как дела друг", "склейка даёт исходный текст")
    check(parts.allSatisfy { $0.utf16.count <= 8 }, "каждый кусок влезает в лимит события")
    let emoji = TextInserter.split("аб😀вг", limit: 3)
    check(emoji.joined() == "аб😀вг", "суррогатная пара не разорвана")
    check(emoji.allSatisfy { $0.utf16.count <= 3 }, "лимит соблюдён и на эмодзи")
}

test("WorkerCommand: модуль диктовки подставляется в аргументы") {
    let c = WorkerCommand(pythonExecutable: URL(fileURLWithPath: "/py"),
                          workerDirectory: URL(fileURLWithPath: "/w"),
                          inboxFolder: URL(fileURLWithPath: "/in"),
                          module: "mlaud_worker.dictate")
    check(c.arguments() == ["-m", "mlaud_worker.dictate"], "аргументы модуля диктовки")
}

// MARK: - Горячая клавиша

test("Combo: перевод модификаторов Cocoa → Carbon") {
    // Наборы битов разные; ошибка здесь зарегистрировала бы не то сочетание.
    let flags = NSEvent.ModifierFlags([.control, .option]).rawValue
    let mods = HotKey.Combo.carbonModifiers(fromCocoa: flags)
    check(mods == UInt32(controlKey | optionKey), "⌃⌥ переведены верно")

    let all = NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue
    check(HotKey.Combo.carbonModifiers(fromCocoa: all)
          == UInt32(controlKey | optionKey | shiftKey | cmdKey), "все четыре модификатора")

    let capsOnly = NSEvent.ModifierFlags([.capsLock]).rawValue
    check(HotKey.Combo.carbonModifiers(fromCocoa: capsOnly) == 0, "capsLock не модификатор хоткея")
}

test("Combo: подпись сочетания в порядке macOS") {
    check(HotKey.Combo.controlOptionD.display == "⌃⌥D", "⌃⌥D")
    let all = HotKey.Combo(keyCode: UInt32(kVK_Space),
                           modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
    check(all.display == "⌃⌥⇧⌘Space", "порядок ⌃⌥⇧⌘, получили \(all.display)")
}

test("Combo: без модификатора невалидно, функциональная клавиша — валидна") {
    check(!HotKey.Combo(keyCode: UInt32(kVK_ANSI_D), modifiers: 0).isValid,
          "голая буква перехватывала бы обычный ввод")
    check(HotKey.Combo(keyCode: UInt32(kVK_F13), modifiers: 0).isValid, "F13 сама по себе годится")
    check(HotKey.Combo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey)).isValid, "⌘D годится")
}

test("KeyNames: физическая клавиша, а не символ раскладки") {
    check(KeyNames.name(for: UInt32(kVK_ANSI_D)) == "D", "D")
    check(KeyNames.name(for: UInt32(kVK_Space)) == "Space", "Space")
    check(KeyNames.name(for: UInt32(kVK_F13)) == "F13", "F13")
    check(KeyNames.name(for: 999).hasPrefix("код"), "неизвестный код не падает")
}

test("HotKey: регистрация и снятие свободной комбинации") {
    let key = HotKey(combo: HotKey.Combo(keyCode: UInt32(kVK_F19),
                                         modifiers: UInt32(controlKey | optionKey | shiftKey))) { }
    check(key.start(), "свободная комбинация занялась")
    check(key.isRegistered, "isRegistered == true")
    let second = HotKey(combo: HotKey.Combo(keyCode: UInt32(kVK_F19),
                                            modifiers: UInt32(controlKey | optionKey | shiftKey))) { }
    check(!second.start(), "повторная регистрация той же комбинации отклонена")
    key.stop()
    check(!key.isRegistered, "после stop() освобождена")
    check(second.start(), "теперь её можно занять заново")
    second.stop()
}

// MARK: summary

print("\n==== Swift tests: \(passed) passed, \(failed) failed ====")
exit(failed == 0 ? 0 : 1)
