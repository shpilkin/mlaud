import AppKit
import Carbon.HIToolbox
import CoreAudio
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

/// Домены тестовых defaults. В конце прогона каждый снимается, но cfprefsd оставляет пустой
/// `{}`-файл и дописывает его уже после выхода процесса — поэтому файлы прошлых прогонов
/// сметаются ещё и при старте, иначе в ~/Library/Preferences копится по plist на тест.
var testSuites: [String] = []
let preferencesDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences")

func sweepTestDefaults() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: preferencesDirectory.path)) ?? []
    for name in names where name.hasPrefix("mlaud.test.") && name.hasSuffix(".plist") {
        try? FileManager.default.removeItem(at: preferencesDirectory.appendingPathComponent(name))
    }
}

func makeDefaults() -> UserDefaults {
    let suite = "mlaud.test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    testSuites.append(suite)
    return d
}

func removeTestDefaults() {
    for suite in testSuites {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    sweepTestDefaults()
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

sweepTestDefaults()

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

test("WorkerCommand: ничего не пишется внутрь бандла") {
    let c = WorkerCommand(pythonExecutable: URL(fileURLWithPath: "/py"),
                          workerDirectory: URL(fileURLWithPath: "/Applications/MLaud.app/Contents/Resources/worker"),
                          inboxFolder: URL(fileURLWithPath: "/in"))
    let env = c.environment(base: [:])
    for key in ["PYTHONPYCACHEPREFIX", "NUMBA_CACHE_DIR"] {
        let path = env[key] ?? ""
        check(!path.isEmpty, "\(key) задан")
        check(!path.contains(".app/"), "\(key) ведёт НАРУЖУ бандла, получили \(path)")
    }
}

// MARK: - Пересборка захвата при смене устройства

test("RebuildPolicy: то же устройство — пересобирать нечего") {
    check(RebuildPolicy.decide(changed: false, sinceLastRebuild: nil, rebuildsInBurst: 0)
          == .unchanged, "устройство не менялось")
    check(RebuildPolicy.decide(changed: true, sinceLastRebuild: nil, rebuildsInBurst: 0)
          == .rebuild, "сменилось — пересобираем")
}

test("RebuildPolicy: замкнутый круг разрывается паузой") {
    // Своя же пересборка останавливает запись, гарнитура уходит в другой профиль и
    // присылает новое уведомление. Без паузы это крутилось раз в две секунды.
    check(RebuildPolicy.decide(changed: true, sinceLastRebuild: 1.0, rebuildsInBurst: 1)
          == .cooldown, "через секунду после пересборки не реагируем")
    check(RebuildPolicy.decide(changed: true, sinceLastRebuild: 5.0, rebuildsInBurst: 1)
          == .rebuild, "после паузы — можно")
}

test("RebuildPolicy: мечущееся устройство перестаём догонять") {
    check(RebuildPolicy.decide(changed: true, sinceLastRebuild: 5.0, rebuildsInBurst: 3)
          == .tooManyRebuilds, "три пересборки подряд — хватит")
    check(RebuildPolicy.decide(changed: true, sinceLastRebuild: 60.0, rebuildsInBurst: 3)
          == .rebuild, "но через минуту тишины серия считается законченной")
}

test("RebuildPolicy: череда уведомлений не зацикливается") {
    // Проигрываем реальную частоту событий из журнала: раз в две секунды.
    var since: TimeInterval? = nil
    var burst = 0
    var rebuilds = 0
    for _ in 0..<12 {
        switch RebuildPolicy.decide(changed: true, sinceLastRebuild: since, rebuildsInBurst: burst) {
        case .rebuild:
            rebuilds += 1; burst += 1; since = 0
        default:
            since = (since ?? 0) + 2
        }
    }
    check(rebuilds <= 3, "двенадцать уведомлений дали не больше трёх пересборок, получили \(rebuilds)")
}

test("AudioCapture: вход по умолчанию определяется и называется") {
    // Движок сам на Bluetooth-гарнитуру не переезжает, поэтому устройство задаётся
    // явно — значит запрос к CoreAudio обязан работать.
    guard let device = AudioCapture.defaultInputDevice() else {
        check(false, "устройство ввода по умолчанию не определилось")
        return
    }
    let name = AudioCapture.deviceName(device)
    check(!name.isEmpty, "у устройства есть имя: \(name)")
    check(!name.hasPrefix("устройство "), "имя настоящее, а не запасное: \(name)")
    print("    (текущий вход: \(name))")
}

test("AudioCapture: частота устройства спрашивается у CoreAudio") {
    // Истина, с которой сверяется движок: он умеет держать формат прежнего входа,
    // и без этой сверки в наушниках получался запуск на несуществующей частоте.
    guard let device = AudioCapture.defaultInputDevice() else {
        check(false, "нет устройства ввода"); return
    }
    guard let rate = AudioCapture.nominalSampleRate(device) else {
        check(false, "частота устройства не прочиталась"); return
    }
    check(rate > 0, "частота положительная: \(Int(rate)) Гц")
    check(rate >= 8000 && rate <= 192000, "частота правдоподобная: \(Int(rate)) Гц")
    print("    (вход \(AudioCapture.deviceName(device)) на \(Int(rate)) Гц)")
}

// MARK: summary

// MARK: - Сопряжение с телефоном

test("PhoneSyncPairingStore: создаёт секрет и переиспользует его") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PhoneSyncPairingStore(url: directory.appendingPathComponent("sync/pairing.json"))

    let first = try store.loadOrCreate()
    eq(first.psk.count, PhoneSyncPairing.pskByteCount, "длина секрета")

    let second = try store.loadOrCreate()
    eq(second.psk, first.psk, "повторный вызов не должен менять секрет")
    eq(second.serverID, first.serverID, "идентификатор сервера постоянный")
}

test("PhoneSyncPairingStore: файл секрета закрыт от чужих") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("sync/pairing.json")
    let store = PhoneSyncPairingStore(url: url)
    _ = try store.loadOrCreate()

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    // Секрет даёт доступ ко всем записям — читать его должен только владелец.
    eq(permissions, 0o600, "права на файл секрета")
}

test("PhoneSyncPairingStore: смена кода даёт новый секрет") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PhoneSyncPairingStore(url: directory.appendingPathComponent("sync/pairing.json"))

    let before = try store.loadOrCreate()
    let after = try store.regenerate()
    check(after.psk != before.psk, "секрет обязан смениться")
    check(store.load()?.psk == after.psk, "новый секрет должен сохраниться")
}

test("SettingsStore: приём с телефона по умолчанию выключен") {
    let settings = SettingsStore(defaults: makeDefaults())
    check(!settings.phoneSyncEnabled, "по умолчанию выключено")
    settings.phoneSyncEnabled = true
    check(settings.phoneSyncEnabled, "значение сохраняется")
}


// MARK: - Журнал уведомлений

func makeJournalURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return directory.appendingPathComponent("notifications.json")
}

test("NotificationHistory: пустой журнал") {
    let url = try makeJournalURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let history = NotificationHistory(url: url)
    eq(history.records.count, 0, "записей нет")
    eq(history.unreadCount, 0, "непрочитанных нет")
}

test("NotificationHistory: новое сверху и считается непрочитанным") {
    let url = try makeJournalURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let history = NotificationHistory(url: url)
    history.append(title: "первое", body: "a")
    history.append(title: "второе", body: "b")
    eq(history.records.map(\.title), ["второе", "первое"], "новые сверху")
    eq(history.unreadCount, 2, "оба непрочитаны")
}

test("NotificationHistory: прочитанное помечается и переживает перезапуск") {
    let url = try makeJournalURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let history = NotificationHistory(url: url)
    let first = history.append(title: "ошибка", body: "worker exit 1")
    history.append(title: "готово", body: "Обработано файлов: 1")

    history.markRead(id: first.id)
    eq(history.unreadCount, 1, "остаётся одно непрочитанное")

    let reopened = NotificationHistory(url: url)
    eq(reopened.records.count, 2, "записи прочитались с диска")
    eq(reopened.unreadCount, 1, "признак прочтения сохранён")
    eq(reopened.records.first?.title, "готово", "порядок сохранён")
    eq(reopened.records.last?.body, "worker exit 1", "текст сохранён целиком")
}

test("NotificationHistory: лимит отбрасывает самые старые") {
    let url = try makeJournalURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let history = NotificationHistory(url: url, limit: 3)
    for i in 1...5 { history.append(title: "n\(i)", body: "") }
    eq(history.records.map(\.title), ["n5", "n4", "n3"], "остаются три последних")
    eq(NotificationHistory(url: url).records.count, 3, "на диске тоже три")
}

test("NotificationHistory: пометить всё прочитанным и очистить") {
    let url = try makeJournalURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let history = NotificationHistory(url: url)
    history.append(title: "a", body: "")
    history.append(title: "b", body: "")

    history.markAllRead()
    eq(history.unreadCount, 0, "непрочитанных не осталось")
    eq(NotificationHistory(url: url).unreadCount, 0, "сохранилось")

    history.clear()
    eq(history.records.count, 0, "журнал пуст")
    eq(NotificationHistory(url: url).records.count, 0, "и на диске пуст")
}

test("NotificationHistory: битый файл не мешает вести журнал дальше") {
    let url = try makeJournalURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("не json".utf8).write(to: url)

    let history = NotificationHistory(url: url)
    eq(history.records.count, 0, "битое содержимое отброшено")
    history.append(title: "после", body: "")
    eq(NotificationHistory(url: url).records.first?.title, "после", "запись поверх битого файла")
}

// MARK: - Подметание недокачанных кусков

test("PhoneSyncStaging: брошенный кусок удаляется, свежий остаётся") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let old = directory.appendingPathComponent("abandoned.part")
    let fresh = directory.appendingPathComponent("resuming.part")
    let alien = directory.appendingPathComponent("readme.txt")
    for url in [old, fresh, alien] { try Data("x".utf8).write(to: url) }
    let longAgo = Date().addingTimeInterval(-PhoneSyncStaging.defaultMaxAge - 60)
    try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)

    let removed = PhoneSyncStaging.sweep(directory: directory)
    eq(removed.map(\.lastPathComponent), ["abandoned.part"], "удалён только брошенный кусок")
    check(!FileManager.default.fileExists(atPath: old.path), "старого куска нет")
    check(FileManager.default.fileExists(atPath: fresh.path), "докачиваемый кусок цел")
    check(FileManager.default.fileExists(atPath: alien.path), "чужие файлы не трогаем")
}

test("PhoneSyncStaging: несуществующая папка не роняет подметание") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    eq(PhoneSyncStaging.sweep(directory: directory).count, 0, "удалять нечего")
}


// MARK: - Голос-ID: команда, настройки, сайдкар

test("WorkerCommand: аргументы подкоманды voices идут после -m") {
    let cmd = WorkerCommand(
        pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
        workerDirectory: URL(fileURLWithPath: "/w"),
        inboxFolder: URL(fileURLWithPath: "/in"),
        module: "mlaud_worker.voices",
        moduleArguments: ["assign", "/s/speakers.json", "SPEAKER_01", "--name", "Милана Г"])
    eq(cmd.arguments(), ["-m", "mlaud_worker.voices", "assign", "/s/speakers.json", "SPEAKER_01", "--name", "Милана Г"], "порядок аргументов")
    let plain = WorkerCommand(pythonExecutable: URL(fileURLWithPath: "/p"),
                              workerDirectory: URL(fileURLWithPath: "/w"),
                              inboxFolder: URL(fileURLWithPath: "/in"))
    eq(plain.arguments(), ["-m", "mlaud_worker"], "без подкоманды — как раньше")
}

test("SettingsStore: идентификация только поверх диаризации") {
    let s = SettingsStore(defaults: makeDefaults())
    check(!s.identifyEnabled, "по умолчанию выключена")
    eq(s.identifyPreset, .balanced, "пресет по умолчанию — баланс")
    check(s.workerEnvironment()["MLAUD_IDENTIFY"] == nil, "выключено — env нет")

    s.identifyEnabled = true
    check(s.workerEnvironment()["MLAUD_IDENTIFY"] == nil, "без диаризации env нет")
    s.diarizeEnabled = true
    eq(s.workerEnvironment()["MLAUD_IDENTIFY"], "1", "с диаризацией — включено")
    eq(s.workerEnvironment()["MLAUD_IDENTIFY_THRESHOLD"], "0.75", "порог пресета")
    s.identifyPreset = .strict
    eq(s.workerEnvironment()["MLAUD_IDENTIFY_THRESHOLD"], "0.80", "строгий пресет")
    eq(SettingsStore(defaults: makeDefaults()).identifyPreset, .balanced, "мусор в defaults → баланс")
}

test("NotificationHistory: поле action переживает перезапись и отсутствует в старых записях") {
    let url = try makeJournalURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = """
    [{"id":"D2A5E0D0-5D2C-4C1E-9C3B-000000000001","title":"старая","body":"без поля",
      "date":"2026-09-01T10:00:00Z","isRead":false}]
    """
    try Data(old.utf8).write(to: url)
    let history = NotificationHistory(url: url)
    eq(history.records.count, 1, "старая запись прочитана")
    check(history.records[0].action == nil, "у старой записи action nil")
    let rec = history.append(title: "готово", body: "к разметке: 2", action: "voices")
    eq(NotificationHistory(url: url).record(id: rec.id)?.action, "voices", "action сохранён")
    check(history.record(id: UUID()) == nil, "неизвестный id → nil")
}

let sidecarJSON = """
{"version": 1, "source": "rec.m4a", "base": "rec", "period": "2026-09",
 "processed_at": "2026-09-03T19:20:11+00:00", "txt": "/out/rec.txt", "srt": "/out/rec.srt",
 "duration_sec": 1284.3, "threshold": 0.75, "min_speech": 30.0,
 "clusters": [
  {"label": "SPEAKER_01", "display": "Спикер 1", "speech_sec": 389.2, "first_at": 0.0, "n_turns": 88,
   "quote": "смотрите", "clips": ["clips/SPEAKER_01_0.wav", "clips/SPEAKER_01_1.wav"],
   "clip_starts": [106.3, 379.8],
   "embedding": [0.1, 0.2, 0.3], "match": {"name": "я", "score": 0.829, "sure": true},
   "written": "я", "assigned": null, "dismissed": false, "mixed": false, "rejected": []},
  {"label": "SPEAKER_00", "display": "Спикер 2", "speech_sec": 367.0, "first_at": 0.5, "n_turns": 40,
   "quote": "", "clips": [], "embedding": [0.1], "match": {"name": "Дина П", "score": 0.77, "sure": false},
   "written": "Дина П(?)", "assigned": null, "dismissed": false, "rejected": []},
  {"label": "SPEAKER_02", "display": "Спикер 3", "speech_sec": 12.0, "first_at": 7.0, "n_turns": 3,
   "quote": "угу", "clips": [], "embedding": [0.1], "match": null,
   "written": "Спикер 3", "assigned": null, "dismissed": false, "rejected": []},
  {"label": "SPEAKER_03", "display": "Спикер 4", "speech_sec": 60.0, "first_at": 9.0, "n_turns": 3,
   "quote": "", "clips": [], "embedding": null, "match": null,
   "written": "Спикер 4", "assigned": null, "dismissed": false, "rejected": []}
 ]}
"""

test("SpeakerSidecar: разбор и смысл полей совпадают с speakers.py") {
    let s = try JSONDecoder().decode(SpeakerSidecar.self, from: Data(sidecarJSON.utf8))
    eq(s.base, "rec", "base")
    eq(s.clusters.count, 4, "кластеры")
    check(s.processedAt != nil, "processed_at разобран")
    let me = s.clusters[0], unsure = s.clusters[1], short = s.clusters[2], padded = s.clusters[3]
    check(me.hasEmbedding && !padded.hasEmbedding, "embedding: есть / null")
    eq(me.currentName, "я", "уверенный — имя как есть")
    eq(unsure.currentName, "Дина П(?)", "неуверенный — с пометкой")
    eq(short.currentName, "Спикер 3", "без узнавания — номер")
    check(!me.needsAttention(minSpeech: s.minSpeech), "уверенный не ждёт разметки")
    check(unsure.needsAttention(minSpeech: s.minSpeech), "неуверенный ждёт")
    check(!short.needsAttention(minSpeech: s.minSpeech), "короткий не ждёт")
    check(!padded.needsAttention(minSpeech: s.minSpeech), "без вектора не ждёт")
    eq(s.pendingCount, 1, "к разметке — один")
    eq(me.clips.count, 2, "клипы")
    eq(me.clipStarts, [106.3, 379.8], "таймкоды клипов")
    check(unsure.clipStarts.isEmpty && !unsure.mixed, "старый формат без clip_starts/mixed читается")

    let mixed = SpeakerCluster(label: "S", display: "Спикер 7", speechSec: 200,
                               match: SpeakerMatch(name: "я", score: 0.9, sure: true), dismissed: true, mixed: true)
    eq(mixed.currentName, "Спикер 7 (смесь голосов)", "смесь — с пометкой в транскрипте, без имени")
    check(!mixed.needsAttention(minSpeech: 30) && mixed.isCollapsed, "смесь свёрнута и не ждёт")
    let hidden = SpeakerCluster(label: "S", display: "Спикер 8", speechSec: 200, hidden: true)
    check(!hidden.needsAttention(minSpeech: 30) && hidden.isCollapsed && hidden.hidden, "убранный корзиной не ждёт")
    check(!s.clusters[0].hidden, "старый формат без hidden читается")

    let rejected = SpeakerCluster(label: "S", display: "Спикер 9", speechSec: 60,
                                  match: SpeakerMatch(name: "я", score: 0.9, sure: true), rejected: ["я"])
    eq(rejected.currentName, "Спикер 9", "«Нет» снимает имя")
    check(rejected.needsAttention(minSpeech: 30), "и возвращает в разметку")
    let assigned = SpeakerCluster(label: "S", display: "Спикер 9", speechSec: 60, assigned: "Кира Л", dismissed: true)
    eq(assigned.currentName, "Кира Л", "assigned важнее dismissed")
    let dismissed = SpeakerCluster(label: "S", display: "Спикер 9", speechSec: 60,
                                   match: SpeakerMatch(name: "я", score: 0.7, sure: false), dismissed: true)
    eq(dismissed.currentName, "Спикер 9", "dismissed — без имени и без (?)")
    check(!dismissed.needsAttention(minSpeech: 30), "dismissed не ждёт")
}

test("SpeakerSidecarStore: новые сверху, битые пропускаются, счётчик суммируется") {
    let root = try makeTempDir()
    func put(_ period: String, _ base: String, _ json: String, at: String) throws {
        let dir = root.appendingPathComponent(period).appendingPathComponent(base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.replacingOccurrences(of: "2026-09-03T19:20:11+00:00", with: at).utf8)
            .write(to: dir.appendingPathComponent(SpeakerSidecarStore.fileName))
    }
    try put("2026-08", "older", sidecarJSON, at: "2026-08-28T14:11:34+00:00")
    try put("2026-09", "newer", sidecarJSON, at: "2026-09-03T16:03:08+00:00")
    try put("2026-09", "broken", "{не json", at: "")
    try put("2026-07", "stone", sidecarJSON.replacingOccurrences(of: "{", with: "{\"removed\": \"swept\",", options: [], range: sidecarJSON.range(of: "{")), at: "2026-07-01T10:00:00+00:00")
    let store = SpeakerSidecarStore(root: root)
    let recent = store.recent()
    eq(recent.map { $0.sidecar.base }, ["rec", "rec"], "две записи, битая пропущена, надгробие тоже")
    let all = store.recent(includeRemoved: true)
    eq(all.count, 3, "с надгробием — три")
    let stone = all.first { $0.sidecar.isRemoved }!
    eq(stone.sidecar.removed, "swept", "причина из файла")
    eq(stone.sidecar.pendingCount, 0, "у надгробия к разметке ноль")
    check(!stone.sidecar.clusters.isEmpty, "имена кластеров у надгробия остались")
    eq(recent.map { $0.url.deletingLastPathComponent().lastPathComponent }, ["newer", "older"], "новые сверху")
    eq(store.pendingCount(), 2, "по одному с записи")
    eq(recent[0].clipURLs(for: recent[0].sidecar.clusters[0]).map(\.lastPathComponent),
       ["SPEAKER_01_0.wav", "SPEAKER_01_1.wav"], "клипы рядом с сайдкаром")
    eq(SpeakerSidecarStore(root: root.appendingPathComponent("nope")).pendingCount(), 0, "нет каталога — ноль")
}

test("VoiceListing: разбор вывода list --json") {
    let json = """
    {"root": "/Users/x/ASR/voices", "people": [
      {"name": "Милана Г", "created": "2026-09-03T10:00:00+00:00",
       "samples": [{"id": "abc", "person": "Милана Г", "source_file": "rec.m4a", "label": "SPEAKER_01",
                    "speech_sec": 130.0, "channel": "phone", "added": "2026-09-03T10:00:00+00:00"}]},
      {"name": "я", "created": "2026-09-01T10:00:00+00:00", "samples": []}]}
    """
    let listing = try VoiceListing.parse(Data(json.utf8))
    eq(listing.names, ["Милана Г", "я"], "имена по порядку")
    eq(listing.people[0].samples[0].channel, "phone", "канал образца")
    eq(listing.people[0].samples[0].speechSec, 130.0, "речь образца")
}


// MARK: RecordingIndex

test("RecordingIndex: сайдкары, старые записи без .meta.json, разметка, итоги суфлёра") {
    let tmp = try makeTempDir()
    let root = tmp.appendingPathComponent("AllOutputs")
    let speakers = tmp.appendingPathComponent("speakers")
    let fm = FileManager.default
    func put(_ dir: URL, _ name: String, _ text: String = "x") throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let sep = root.appendingPathComponent("2026-09")
    try put(sep, "2026-09-03_21-43-04_Запись 15.txt")
    try put(sep, "2026-09-03_21-43-04_Запись 15.srt")
    try put(sep, "2026-09-03_21-43-04_Запись 15.prompter.md")
    try put(sep, "2026-09-03_21-43-04_Запись 15.meta.json", """
    {"meeting_id": "044d", "started_at": "2026-09-03T21:43:05+03:00", "duration_sec": 9,
     "asr_root": "\(tmp.path)", "audio_path": "Processed/AllRecords/2026-09/x.m4a", "source": "mlaud"}
    """)
    try put(sep, "rec.txt")
    try put(sep, "rec.meta.json", #"{"started_at": "2026-09-01T10:00:00+03:00", "duration_sec": 1284.3}"#)
    try put(sep, "битый.txt")
    try put(sep, "битый.meta.json", "{не json")
    try put(sep, ".DS_Store")
    let aug = root.appendingPathComponent("2026-08")
    try put(aug, "2026-08-20_10-00-00_Запись 7.txt")
    try put(speakers.appendingPathComponent("2026-08/2026-08-20_10-00-00_Запись 7"), "speakers.json",
            sidecarJSON.replacingOccurrences(of: "{", with: "{\"removed\": \"forgotten\",", options: [], range: sidecarJSON.range(of: "{"))
                .replacingOccurrences(of: "\"base\": \"rec\", \"period\": \"2026-09\"",
                                      with: "\"base\": \"2026-08-20_10-00-00_Запись 7\", \"period\": \"2026-08\""))
    let old = root.appendingPathComponent("2026-07")
    try put(old, "Старая запись.txt")
    try put(old, "Старая запись.srt")
    let mtime = Date(timeIntervalSince1970: 1_753_000_000)  // 2025-07-20
    try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: old.appendingPathComponent("Старая запись.txt").path)
    try put(root, "не каталог.txt")
    try put(speakers.appendingPathComponent("2026-09/rec"), "speakers.json", sidecarJSON)
    let archive = tmp.appendingPathComponent("Processed/AllRecords")
    try put(archive.appendingPathComponent("2026-07"), "Старая запись.m4a")
    try put(archive.appendingPathComponent("2026-07"), "Старая запись.txt")   // не аудио — не в счёт
    try put(archive.appendingPathComponent("2026-08"), "другая.m4a")
    // Запись звонка: аудио и сайдкар каналов в архиве, разметки голосов нет.
    try put(archive.appendingPathComponent("2026-09"), "2026-09-03_21-43-04_Запись 15.m4a")
    try put(archive.appendingPathComponent("2026-09"), "2026-09-03_21-43-04_Запись 15.channels.json",
            #"{"version":1,"call_id":"2026-09-03_21-43-04","channels":{"0":"Я","1":"Иван Петров"}}"#)

    let recs = RecordingIndex(root: root, speakersRoot: speakers).scan()
    // «битый» без годного сайдкара датируется созданием файла — то есть «сейчас»,
    // поэтому он выше сентябрьских записей с точной датой.
    eq(recs.map(\.base), ["битый", "2026-09-03_21-43-04_Запись 15", "rec", "2026-08-20_10-00-00_Запись 7", "Старая запись"], "новые сверху, файл в корне пропущен")

    let full = recs[1]
    check(full.dateIsExact, "дата из сайдкара")
    eq(full.durationSec, 9, "длительность")
    eq(full.srt?.lastPathComponent, "2026-09-03_21-43-04_Запись 15.srt", "srt рядом")
    eq(full.audio?.path, tmp.appendingPathComponent("Processed/AllRecords/2026-09/x.m4a").path, "аудио от asr_root")
    check(full.hasPrompter, "итоги суфлёра найдены")
    check(full.speakers.isEmpty && !full.needsLabeling, "без сайдкара разметки — без говорящих")
    eq(full.id, "2026-09/2026-09-03_21-43-04_Запись 15", "id = период/base")

    let rec = recs[2]
    eq(rec.speakers, ["я", "Дина П(?)", "Спикер 4"], "имена: уверенный, неуверенный с пометкой, длинный без имени; короткий выброшен")
    check(rec.needsLabeling, "неуверенный кластер — к разметке")
    eq(rec.durationSec, 1284.3, "длительность из сайдкара")

    let broken = recs[0]
    check(!broken.dateIsExact && broken.durationSec == nil, "битый сайдкар = как без сайдкара")

    let named = recs[3]
    check(named.dateIsExact && named.durationSec == nil, "дата из имени файла — точная, длительности нет")
    check(named.hasSidecar && !named.needsLabeling, "надгробие сайдкара: сайдкар есть, к разметке ничего")
    eq(named.speakers, ["я", "Дина П(?)", "Спикер 4"], "имена говорящих из надгробия остались")
    var stamp = DateComponents(); stamp.year = 2026; stamp.month = 8; stamp.day = 20; stamp.hour = 10
    eq(named.date, Calendar.current.date(from: stamp), "2026-08-20 10:00 по местному времени")
    check(RecordingIndex.dateFromName("2026-13-40_99-00-00_x") == nil, "мусорная дата в имени — nil")
    check(RecordingIndex.dateFromName("Старая запись") == nil, "без штампа — nil")

    let legacy = recs[4]
    check(!legacy.dateIsExact, "без сайдкара дата не точная")
    eq(legacy.date, mtime, "дата — mtime транскрипта")
    check(legacy.durationSec == nil && legacy.srt != nil && legacy.audio == nil, "без архива: без длительности и аудио, srt есть")
    check(!legacy.hasSidecar && rec.hasSidecar && !full.hasSidecar, "сайдкар есть только у rec")

    // С архивом аудио: у записи без .meta.json аудио — файл с тем же именем в месяце архива.
    let withArchive = RecordingIndex(root: root, speakersRoot: speakers, archiveRoot: archive).scan()
    let legacy2 = withArchive.first { $0.base == "Старая запись" }!
    eq(legacy2.audio?.resolvingSymlinksInPath().path,
       archive.appendingPathComponent("2026-07/Старая запись.m4a").resolvingSymlinksInPath().path, "аудио из архива по имени")
    check(withArchive.first { $0.base == "2026-08-20_10-00-00_Запись 7" }!.audio == nil, "чужое имя в месяце архива не подходит")
    eq(withArchive.first { $0.base == "rec" }!.audio, nil, "у rec .meta.json без audio_path и аудио в архиве нет")
    let call = withArchive.first { $0.base == "2026-09-03_21-43-04_Запись 15" }!
    check(call.isCall && !call.hasSidecar, "звонок: сайдкар каналов есть, разметки голосов нет")
    eq(call.speakers, ["Я", "Иван Петров"], "имена говорящих звонка — из сайдкара каналов")
    check(!recs.first { $0.base == "2026-09-03_21-43-04_Запись 15" }!.isCall, "без архива признак звонка не читается")
    let candidates = RecordingIndex.labelingCandidates(withArchive)
    eq(candidates.ready.map(\.base), ["Старая запись"], "разметить заново можно тех, у кого нашёлся файл; звонок — нет")
    eq(candidates.noAudio.map(\.base), ["битый"],
       "без сайдкара и без файла: битый сайдкар; Запись 15 — звонок, rec с сайдкаром и Запись 7 с надгробием не в списке")

    let groups = RecordingIndex.grouped(recs)
    eq(groups.map(\.period), ["2026-09", "2026-08", "2026-07"], "периоды в порядке записей")
    eq(groups[0].items.count, 3, "три записи сентября")

    eq(RecordingIndex(root: tmp.appendingPathComponent("нет")).scan().count, 0, "нет каталога — пусто")
}

test("RecordingIndex: без сайдкара дата — самая ранняя из создания и изменения; вне месяца каталога — не дата") {
    let tmp = try makeTempDir()
    let root = tmp.appendingPathComponent("AllOutputs")
    let fm = FileManager.default
    let aug = root.appendingPathComponent("2026-08")
    try fm.createDirectory(at: aug, withIntermediateDirectories: true)
    func put(_ name: String, created: Date, modified: Date) throws {
        let url = aug.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
    }
    let cal = Calendar.current
    let aug17 = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 10, minute: 40))!
    let sep5 = cal.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 0, minute: 29))!
    let aug20 = cal.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 9))!
    // Транскрипт переписан переразметкой 5 сентября: mtime врёт, создание — правда.
    try put("17.08 заметка.txt", created: aug17, modified: sep5)
    // Скопирован в архив целиком уже в сентябре: обе даты вне августа.
    try put("чужой.txt", created: sep5, modified: sep5)
    try put("2026-08-20_10-00-00_Запись 7.txt", created: sep5, modified: sep5)
    _ = aug20

    let recs = RecordingIndex(root: root).scan()
    eq(recs.map(\.base), ["2026-08-20_10-00-00_Запись 7", "17.08 заметка", "чужой"],
       "точная дата, затем правдоподобная, чужая — в конец несмотря на поздний mtime")
    let rewritten = recs[1]
    eq(rewritten.date, aug17, "дата создания, а не изменения")
    check(!rewritten.dateIsExact && rewritten.dateFitsPeriod, "приблизительная, но в своём месяце")
    let foreign = recs[2]
    check(!foreign.dateIsExact && !foreign.dateFitsPeriod, "вне месяца каталога — показывать нельзя")
    check(recs[0].dateIsExact, "дата из имени файла точная")

    check(RecordingIndex.month(ofPeriod: "2026-06-21")! == (2026, 6), "старый каталог по дню — тоже месяц")
    check(RecordingIndex.month(ofPeriod: "прочее") == nil, "не период — nil")
    check(RecordingIndex.month(ofPeriod: "2026-13") == nil, "месяц 13 — nil")
}

test("RecordingIndex.matches: по имени, говорящим и дате, все слова запроса") {
    let cal = Calendar.current
    let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 21, minute: 43))!
    let rec = Recording(id: "2026-09/2026-09-03_21-43-04_Запись 15", base: "2026-09-03_21-43-04_Запись 15",
                        period: "2026-09", txt: URL(fileURLWithPath: "/x.txt"), srt: nil, audio: nil,
                        date: date, dateIsExact: true, durationSec: nil,
                        speakers: ["я", "Дина П(?)", "Спикер 4"], needsLabeling: true, hasPrompter: false)
    check(RecordingIndex.matches(rec, query: ""), "пустой запрос — всё")
    check(RecordingIndex.matches(rec, query: "дина"), "по говорящему, без учёта регистра")
    check(RecordingIndex.matches(rec, query: "запись 15"), "по имени, два слова")
    check(RecordingIndex.matches(rec, query: "03.09"), "по дате дд.мм")
    check(RecordingIndex.matches(rec, query: "2026-09-03 дина"), "дата и говорящий вместе")
    check(!RecordingIndex.matches(rec, query: "дина бухгалтер"), "одно слово не нашлось — нет")
    let foreign = Recording(id: "2026-08/чужой", base: "чужой", period: "2026-08",
                            txt: URL(fileURLWithPath: "/y.txt"), srt: nil, audio: nil,
                            date: date, dateIsExact: false, durationSec: nil,
                            speakers: [], needsLabeling: false, hasPrompter: false)
    check(!RecordingIndex.matches(foreign, query: "03.09"), "недостоверная дата в поиск не идёт")
}

test("VoicesPresentation.needsNameField: поле имени только там, где имя ещё не стоит") {
    let s = try JSONDecoder().decode(SpeakerSidecar.self, from: Data(sidecarJSON.utf8))
    check(!VoicesPresentation.needsNameField(s.clusters[0]), "уверенно узнан — поля нет, имя меняют карандашом")
    check(VoicesPresentation.needsNameField(s.clusters[1]), "неуверенный — поле есть")
    check(VoicesPresentation.needsNameField(s.clusters[2]), "короткий — поле есть, имя пойдёт в транскрипт")
    check(!VoicesPresentation.needsNameField(SpeakerCluster(label: "S", display: "Спикер 9", speechSec: 60, assigned: "Кира Л")),
          "подписан — поля нет")
    check(!VoicesPresentation.needsNameField(SpeakerCluster(label: "S", display: "Спикер 7", speechSec: 200, dismissed: true, mixed: true)),
          "свёрнут — поля нет")
    let rejected = SpeakerCluster(label: "S", display: "Спикер 9", speechSec: 60,
                                  match: SpeakerMatch(name: "я", score: 0.9, sure: true), rejected: ["я"])
    check(VoicesPresentation.needsNameField(rejected), "после «Не он» поле возвращается")
}

// MARK: OverviewState

test("RussianPlural: формы") {
    for (n, want) in [(1, "файл"), (2, "файла"), (5, "файлов"), (11, "файлов"), (21, "файл"), (112, "файлов"), (0, "файлов")] {
        eq(RussianPlural.form(n, "файл", "файла", "файлов"), want, "\(n)")
    }
}

test("OverviewState: правила показа") {
    var s = OverviewState()
    check(!s.hasFolder && !s.canProcessNow, "без папки обработка недоступна")
    eq(s.pipeline.tone, .muted, "без папки — приглушённая плашка")
    check(s.queueLines.isEmpty && s.deliveryLine == nil, "пустая очередь — без строк")

    s.inboxPath = "/x"; s.status = .idle
    check(s.canProcessNow, "папка есть, ничего не идёт — можно")
    s.status = .processing(current: 1, total: 3)
    check(s.isProcessing && !s.canProcessNow, "во время обработки нельзя")
    eq(s.pipeline.tone, .accent, "обработка — акцент")
    s.status = .error("worker exit 1")
    eq(s.pipeline.tone, .danger, "ошибка — danger")
    eq(s.pipeline.text, "Ошибка: worker exit 1", "текст как в меню")

    s.ready = 2; s.downloading = 1; s.pendingDelivery = 5
    eq(s.queueLines, ["2 файла ждут обработки", "1 докачивается из iCloud"], "очередь")
    eq(s.deliveryLine, "5 файлов ждут отправки в Telegram", "доставка")
    s.ready = 1; s.downloading = 3
    eq(s.queueLines, ["1 файл ждёт обработки", "3 докачиваются из iCloud"], "единственное число")
}

test("InboxScanner: докачивающиеся из iCloud") {
    let dir = try makeTempDir()
    try writeFile(dir, ".a.m4a.icloud")
    try writeFile(dir, "b.m4a")
    try writeFile(dir, ".c.txt.icloud")
    try writeFile(dir, ".hidden.m4a")
    let names = InboxScanner().downloadingAudioFiles(in: dir).map(\.lastPathComponent)
    eq(names, [".a.m4a.icloud"], "только плейсхолдеры аудио")
}


test("PhoneReceipts: журнал приёма — словарь по id, новые сверху, битый файл пуст") {
    let json = """
    {"a1": {"deviceID": "D", "id": "a1", "name": "2026-08-31_16-37-45_Запись 10.m4a",
            "receivedAt": "2026-09-01T16:17:01Z", "sha256": "…", "size": 100},
     "b2": {"id": "b2", "name": "2026-09-03_21-43-04_Запись 15.m4a",
            "receivedAt": "2026-09-03T18:43:14.250Z", "size": 54305}}
    """
    let list = PhoneReceipts.parse(Data(json.utf8))
    eq(list.map(\.id), ["b2", "a1"], "новые сверху, доли секунды читаются")
    eq(list[0].size, 54305, "размер")
    check(list[0].deviceID == nil && list[1].deviceID == "D", "deviceID необязателен")
    eq(PhoneReceipts.parse(Data("{не json".utf8)).count, 0, "битый — пусто")
    eq(PhoneReceipts.load(URL(fileURLWithPath: "/nonexistent/received.json")).count, 0, "нет файла — пусто")
}

// MARK: VoicesPresentation

test("VoicesPresentation: подписи записи и карточек — как в прежнем окне") {
    let s = try JSONDecoder().decode(SpeakerSidecar.self, from: Data(sidecarJSON.utf8))
    eq(VoicesPresentation.recordingStatus(s), "1 к разметке", "ждёт один")
    eq(VoicesPresentation.mmss(389.2), "6:29", "минуты:секунды")
    eq(VoicesPresentation.clusterTitle(s.clusters[0]), "Спикер 1 · 6:29 речи · с 0:00", "заголовок карточки")
    eq(VoicesPresentation.clusterSubtitle(s.clusters[0], minSpeech: 30), "«смотрите»", "длинный — цитата")
    eq(VoicesPresentation.clusterSubtitle(s.clusters[2], minSpeech: 30),
       "речи меньше 0:30: имя пойдёт только в транскрипт, отпечаток в базу не снять · «угу»",
       "короткий — объяснение FR-8.9 и цитата")
    eq(VoicesPresentation.clusterSubtitle(s.clusters[1], minSpeech: 30), "", "без цитаты — пусто")
    eq(VoicesPresentation.clipTitle(s.clusters[0], index: 1), "6:19", "таймкод клипа")
    eq(VoicesPresentation.clipTitle(s.clusters[1], index: 0), "1", "без clip_starts — номер")

    eq(VoicesPresentation.badge(for: s.clusters[0]), .sure("я", 0.829), "уверенный")
    eq(VoicesPresentation.badge(for: s.clusters[0])?.text, "✓ я · 0.83", "плашка уверенного")
    eq(VoicesPresentation.badge(for: s.clusters[1])?.text, "Дина П (?) · 0.77", "плашка неуверенного")
    check(VoicesPresentation.badge(for: s.clusters[2]) == nil, "не узнан — плашки нет")
    let assigned = SpeakerCluster(label: "S", display: "Спикер 9", speechSec: 60, assigned: "Кира Л")
    eq(VoicesPresentation.badge(for: assigned), .assigned("Кира Л"), "подписан")
    let mixed = SpeakerCluster(label: "S", display: "Спикер 7", speechSec: 200, dismissed: true, mixed: true)
    eq(VoicesPresentation.badge(for: mixed)?.text, "смесь / неразборчиво", "смесь")
    let hidden = SpeakerCluster(label: "S", display: "Спикер 8", speechSec: 200, hidden: true)
    eq(VoicesPresentation.badge(for: hidden), .hidden, "убран корзиной")
    let dismissed = SpeakerCluster(label: "S", display: "Спикер 8", speechSec: 200, dismissed: true)
    eq(VoicesPresentation.badge(for: dismissed), .unnamed, "оставлен без имени")
    eq(VoicesPresentation.clusterSubtitle(dismissed, minSpeech: 30), "", "свёрнутый короткого объяснения не получает")

    let allNamed = """
    {"source": "a.m4a", "min_speech": 30, "clusters": [
      {"label": "S1", "display": "Спикер 1", "speech_sec": 100, "embedding": [0.1], "assigned": "я"}]}
    """
    eq(VoicesPresentation.recordingStatus(try JSONDecoder().decode(SpeakerSidecar.self, from: Data(allNamed.utf8))),
       "все названы", "все названы")
    let shortOnly = """
    {"source": "a.m4a", "min_speech": 30, "clusters": [
      {"label": "S1", "display": "Спикер 1", "speech_sec": 10, "embedding": [0.1]}]}
    """
    eq(VoicesPresentation.recordingStatus(try JSONDecoder().decode(SpeakerSidecar.self, from: Data(shortOnly.utf8))),
       "нечего размечать: речи меньше 30 с", "нечего размечать")
}

test("VoicesPresentation: строки вкладки «Люди»") {
    let json = """
    {"root": "/v", "people": [
      {"name": "Милана Г", "created": "2026-09-03T10:00:00+00:00", "samples": [
        {"id": "a1", "source_file": "rec.m4a", "label": "SPEAKER_01", "speech_sec": 54.6,
         "channel": "phone", "added": "2026-09-03T10:00:00+00:00"}]},
      {"name": "я", "created": "2026-08-20T10:00:00+00:00", "samples": [
        {"id": "b1", "source_file": "a.m4a", "label": "S", "speech_sec": 300, "channel": "vks", "added": "2026-08-20T10:00:00+00:00"},
        {"id": "b2", "source_file": "b.m4a", "label": "S", "speech_sec": 120, "channel": "weird", "added": "2026-08-21T10:00:00+00:00"},
        {"id": "b3", "source_file": "c.m4a", "label": "S", "speech_sec": 45, "channel": "other", "added": "2026-08-22T10:00:00+00:00"},
        {"id": "b4", "source_file": "d.m4a", "label": "S", "speech_sec": 45, "channel": "other", "added": "2026-08-23T10:00:00+00:00"},
        {"id": "b5", "source_file": "e.m4a", "label": "S", "speech_sec": 45, "channel": "other", "added": "2026-08-24T10:00:00+00:00"}]}
    ]}
    """
    let listing = try VoiceListing.parse(Data(json.utf8))
    eq(VoicesPresentation.personLine(listing.people[0]), "1 образец · с 2026-09-03", "один образец")
    eq(VoicesPresentation.personLine(listing.people[1]), "5 образцов · с 2026-08-20", "пять образцов")
    eq(VoicesPresentation.sampleLine(listing.people[0].samples[0]), "54 с · телефон · rec.m4a · 2026-09-03", "образец")
    eq(VoicesPresentation.sampleLine(listing.people[1].samples[1]), "120 с · weird · b.m4a · 2026-08-21", "неизвестный канал — как есть")
    eq(VoicesPresentation.channelTitle("vks"), "ВКС", "канал")
    eq(VoicesPresentation.channels.map(\.value), ["phone", "vks", "other", "reference"], "порядок каналов — как в worker'е (эталон — этап 5)")
    eq(listing.people.map(\.id), ["Милана Г", "я"], "человек идентифицируется именем")
}

// MARK: - Этап 3, волна 0: общие типы звонка

test("JSONText: числа не больше двух знаков, хвостовые нули срезаны") {
    eq(JSONText.number(183.2), "183.2", "183.2")
    eq(JSONText.number(190.0), "190", "190.0 → 190")
    eq(JSONText.number(0.049), "0.05", "0.049 → 0.05")
    eq(JSONText.number(-0.0), "0", "-0.0 → 0")
    eq(JSONText.number(0), "0", "0")
    eq(JSONText.number(7.4), "7.4", "7.4")
    eq(JSONText.number(612.4), "612.4", "612.4")
    eq(JSONText.number(0.3 + 0.6), "0.9", "0.9 без хвоста двоичной дроби")
    eq(JSONText.number(-1.5), "-1.5", "отрицательное")
    eq(JSONText.number(1234567.891), "1234567.89", "два знака")
}

test("JSONText: строки экранируются, кириллица как есть") {
    eq(JSONText.quoted("Собеседник"), "\"Собеседник\"", "кириллица как есть")
    eq(JSONText.quoted("a\"b\\c"), #""a\"b\\c""#, "кавычка и слэш")
    eq(JSONText.quoted("x\ny\r\tz"), #""x\ny\r\tz""#, "переводы строк и табуляция")
    eq(JSONText.quoted("\u{01}"), #""\u0001""#, "управляющий символ")
    eq(JSONText.quoted(""), "\"\"", "пустая")
}

test("ChannelsSidecar: байты примера §3.1 с брифом и без") {
    let plain = ChannelsSidecar(callID: "2026-09-04_15-30-05", themLabel: "Собеседник")
    eq(String(decoding: plain.encoded(), as: UTF8.self),
       #"{"version":1,"call_id":"2026-09-04_15-30-05","channels":{"0":"Я","1":"Собеседник"}}"# + "\n",
       "без брифа — ключ опущен")
    let withBrief = ChannelsSidecar(callID: "2026-09-04_15-30-05", themLabel: "Иван Петров", brief: "тема: «бюджет»")
    eq(String(decoding: withBrief.encoded(), as: UTF8.self),
       #"{"version":1,"call_id":"2026-09-04_15-30-05","channels":{"0":"Я","1":"Иван Петров"},"brief":"тема: «бюджет»"}"# + "\n",
       "с брифом")
    eq(ChannelsSidecar.fileName(callID: "2026-09-04_15-30-05"), "2026-09-04_15-30-05.channels.json", "имя файла")
    eq(withBrief.label(.me), "Я", "метка me")
    eq(withBrief.label(.them), "Иван Петров", "метка them")
    eq(CallChannel.me.key, "0", "ключ me")
    eq(CallChannel.them.key, "1", "ключ them")
}

test("ChannelsSidecar: круговой decode и отказ на чужой версии") {
    let original = ChannelsSidecar(callID: "2026-09-04_15-30-05", themLabel: "Иван Петров", brief: "б")
    eq(try ChannelsSidecar.decode(original.encoded()), original, "с брифом")
    let plain = ChannelsSidecar(callID: "2026-09-04_15-30-05", themLabel: "Собеседник")
    eq(try ChannelsSidecar.decode(plain.encoded()), plain, "без брифа")
    let v2 = Data(#"{"version":2,"call_id":"x","channels":{"0":"Я","1":"С"}}"#.utf8)
    check((try? ChannelsSidecar.decode(v2)) == nil, "version 2 отвергнут")
    let noThem = Data(#"{"version":1,"call_id":"x","channels":{"0":"Я"}}"#.utf8)
    check((try? ChannelsSidecar.decode(noThem)) == nil, "без канала 1 отвергнут")
    let notString = Data(#"{"version":1,"call_id":"x","channels":{"0":"Я","1":5}}"#.utf8)
    check((try? ChannelsSidecar.decode(notString)) == nil, "метка не строка — отвергнут")
    check((try? ChannelsSidecar.decode(Data("мусор".utf8))) == nil, "не JSON — отвергнут")
}

test("ChannelsSidecar: имя собеседника — до первой запятой") {
    eq(ChannelsSidecar.themLabel(counterpart: "Иван Петров, кандидат"), "Иван Петров", "до запятой")
    eq(ChannelsSidecar.themLabel(counterpart: "Иван Петров"), "Иван Петров", "без запятой")
    eq(ChannelsSidecar.themLabel(counterpart: ""), "Собеседник", "пусто")
    eq(ChannelsSidecar.themLabel(counterpart: "  , x"), "Собеседник", "пробелы до запятой")
    eq(ChannelsSidecar.themLabel(counterpart: nil), "Собеседник", "nil")
}

test("ChannelsSidecar: call_id из даты в зоне +3 и обратно") {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
    let date = Date(timeIntervalSince1970: 1_788_525_005)   // 2026-09-04T12:30:05Z
    eq(ChannelsSidecar.callID(startedAt: date, calendar: calendar), "2026-09-04_15-30-05", "в зоне +3")
    eq(ChannelsSidecar.startedAt(callID: "2026-09-04_15-30-05", calendar: calendar), date, "обратно")
    check(ChannelsSidecar.startedAt(callID: "мусор", calendar: calendar) == nil, "мусор → nil")
}

test("ChannelCommand: пять строк протокола байт в байт") {
    eq(ChannelCommand.open(ch: "them", label: "Собеседник").line(),
       #"{"t":"open","ch":"them","label":"Собеседник"}"#, "open")
    eq(ChannelCommand.audio(ch: "them", pcm: Data([0x01, 0x02])).line(),
       #"{"t":"audio","ch":"them","pcm":"AQI="}"#, "audio")
    eq(ChannelCommand.flush(ch: "them").line(), #"{"t":"flush","ch":"them"}"#, "flush")
    eq(ChannelCommand.reset(ch: "them").line(), #"{"t":"reset","ch":"them"}"#, "reset")
    eq(ChannelCommand.close(ch: "them").line(), #"{"t":"close","ch":"them"}"#, "close")
    eq(ChannelCommand.open(ch: "me", label: "Иван \"Ваня\"\nПетров").line(),
       #"{"t":"open","ch":"me","label":"Иван \"Ваня\"\nПетров"}"#, "метка с кавычкой и переводом строки")
    eq(String(decoding: ChannelCommand.close(ch: "me").data(), as: UTF8.self),
       #"{"t":"close","ch":"me"}"# + "\n", "data — строка с переводом строки")
}

test("RecognizerEvent: с ch — событие канала, без — диктовки") {
    eq(RecognizerEvent.parse(line: #"{"t":"commit","ch":"them","phrase":12,"text":"да"}"#),
       .channel(ch: "them", .commit(phrase: 12, text: "да")), "commit")
    eq(RecognizerEvent.parse(line: #"{"t":"preview","ch":"me","phrase":3,"text":"ну"}"#),
       .channel(ch: "me", .preview(phrase: 3, text: "ну")), "preview")
    eq(RecognizerEvent.parse(line: #"{"t":"phrase","ch":"them","phrase":12,"t0":183.2,"t1":190.6,"text":"вся фраза","reason":"silence","window_sec":7.4,"decodes":18}"#),
       .channel(ch: "them", .phrase(ChannelPhrase(phrase: 12, t0: 183.2, t1: 190.6, text: "вся фраза",
                                                  reason: "silence", windowSec: 7.4, decodes: 18))), "phrase")
    eq(RecognizerEvent.parse(line: #"{"t":"phrase","ch":"them","phrase":1,"t0":0,"t1":5,"text":"","reason":"flush","window_sec":5,"decodes":2}"#),
       .channel(ch: "them", .phrase(ChannelPhrase(phrase: 1, t0: 0, t1: 5, text: "",
                                                  reason: "flush", windowSec: 5, decodes: 2))), "phrase с целыми числами")
    eq(RecognizerEvent.parse(line: #"{"t":"error","ch":"main","message":"канал main зарезервирован"}"#),
       .channel(ch: "main", .error("канал main зарезервирован")), "error с ch")
    eq(RecognizerEvent.parse(line: #"{"t":"ready"}"#), .dictation(.ready), "ready — диктовка")
    eq(RecognizerEvent.parse(line: #"{"t":"stat","reason":"manual","window_sec":2.5,"decodes":4}"#),
       .dictation(.stat(reason: "manual", windowSec: 2.5, decodes: 4)), "stat без ch — диктовка")
    eq(RecognizerEvent.parse(line: #"{"t":"commit","text":"привет"}"#), .dictation(.commit("привет")), "commit без ch — диктовка")
    check(RecognizerEvent.parse(line: #"{"t":"phrase"}"#) == nil, "phrase без ch — nil")
    check(RecognizerEvent.parse(line: #"{"t":"stat","ch":"them"}"#) == nil, "stat с ch — nil")
    check(RecognizerEvent.parse(line: "UserWarning: torchaudio deprecated") == nil, "не JSON — nil")
}

// MARK: - Этап 3, Swift Core: машина звонка, лента, форматы, звук

func pcm16(_ samples: [Int16]) -> Data {
    var out = Data(capacity: samples.count * 2)
    for s in samples {
        let v = UInt16(bitPattern: s)
        out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8))
    }
    return out
}

func samples16(_ data: Data) -> [Int16] {
    stride(from: 0, to: data.count - 1, by: 2).map {
        Int16(bitPattern: UInt16(data[data.startIndex + $0]) | (UInt16(data[data.startIndex + $0 + 1]) << 8))
    }
}

test("CallSession: полный путь idle→ready→running→finishing→done→idle") {
    var clock = Date(timeIntervalSince1970: 1_788_525_005)
    let session = CallSession(now: { clock })
    var changes = 0
    session.onChange = { _ in changes += 1 }
    eq(session.snapshot.phase, .idle, "старт — idle")
    session.apply(.start)
    session.apply(.stop)
    eq(session.snapshot.phase, .idle, "start/stop из idle игнорируются")
    eq(changes, 0, "игнорированные переходы не дёргают onChange")

    session.apply(.prepare(callID: "черновик", title: "Звонок"))
    eq(session.snapshot.phase, .ready, "prepare → ready")
    session.apply(.stop)
    eq(session.snapshot.phase, .ready, "stop из ready игнорируется")
    session.apply(.start)
    eq(session.snapshot.phase, .ready, "start без микрофона игнорируется")
    session.apply(.checklist(microphone: .ok, appAudio: .needsRestart))
    session.apply(.devices(input: "MacBook Pro Microphone", output: "AirPods Pro", app: "zoom.us"))
    session.apply(.headphones(true))
    session.apply(.channel(.them, .noAudio("приложение закрыто")))
    check(session.snapshot.canStart, "микрофон ok — можно стартовать, звук приложения не обязателен")
    session.apply(.prepare(callID: "2026-09-04_15-30-05", title: "Звонок"))
    eq(session.snapshot.phase, .ready, "prepare в ready остаётся ready")
    eq(session.snapshot.microphone, .ok, "prepare в ready не сбрасывает чек-лист")
    eq(session.snapshot.callID, "2026-09-04_15-30-05", "callID обновлён")

    session.apply(.start)
    eq(session.snapshot.phase, .running, "start → running")
    eq(session.snapshot.startedAt, clock, "startedAt по подставным часам")
    eq(session.snapshot.them, .noAudio("приложение закрыто"), "деградация канала сохранена")
    session.apply(.dismiss)
    eq(session.snapshot.phase, .running, "dismiss из running игнорируется")
    session.apply(.failed("распознаватель упал"))
    eq(session.snapshot.phase, .running, "failed в running оставляет фазу")
    eq(session.snapshot.error, "распознаватель упал", "ошибка записана")
    session.apply(.recognizer(.restarting(attempt: 1)))
    session.apply(.level(.me, 0.4))
    session.apply(.recorded(12.5))
    let line = TranscriptLine(id: 1, ch: .me, label: "Я", t0: 0, t1: 1, text: "да")
    session.apply(.transcript(lines: [line], tails: [.them: "ну"]))
    eq(session.snapshot.levels.me, 0.4, "уровень")
    eq(session.snapshot.recordedSec, 12.5, "записано")
    eq(session.snapshot.lines, [line], "строки")
    eq(session.snapshot.tails[.them], "ну", "хвост")

    clock = clock.addingTimeInterval(1); session.apply(.tick)
    clock = clock.addingTimeInterval(1); session.apply(.tick)
    clock = clock.addingTimeInterval(1); session.apply(.tick)
    eq(session.snapshot.elapsed, 3, "три тика по секунде")

    session.apply(.finalized(URL(fileURLWithPath: "/x.m4a")))
    eq(session.snapshot.phase, .running, "finalized из running игнорируется")
    session.apply(.stop)
    eq(session.snapshot.phase, .finishing, "stop → finishing")
    clock = clock.addingTimeInterval(5); session.apply(.tick)
    eq(session.snapshot.elapsed, 3, "после stop таймер стоит")
    let result = URL(fileURLWithPath: "/inbox/2026-09-04_15-30-05.m4a")
    session.apply(.finalized(result))
    eq(session.snapshot.phase, .done, "finalized → done")
    eq(session.snapshot.result, result, "результат")
    session.apply(.dismiss)
    eq(session.snapshot, CallSnapshot(), "dismiss → чистый снимок")
    check(changes > 0, "onChange звался")
}

test("CallSession: failed в finishing — done с ошибкой; dismiss из ready") {
    let session = CallSession(now: { Date(timeIntervalSince1970: 0) })
    session.apply(.prepare(callID: "a", title: "Звонок"))
    session.apply(.checklist(microphone: .ok, appAudio: .ok))
    session.apply(.start)
    session.apply(.stop)
    session.apply(.failed("afconvert: код 1"))
    eq(session.snapshot.phase, .done, "ошибка конвертации завершает звонок")
    eq(session.snapshot.error, "afconvert: код 1", "текст ошибки")
    check(session.snapshot.result == nil, "результата нет")
    session.apply(.dismiss)
    eq(session.snapshot.phase, .idle, "dismiss из done")
    session.apply(.prepare(callID: "b", title: "Звонок"))
    session.apply(.dismiss)
    eq(session.snapshot.phase, .idle, "dismiss из ready")
}

test("LiveTranscript: строка §3.3 байт в байт") {
    eq(LiveTranscript.encodeLine(ch: .them, label: "Иван Петров", t0: 183.2, t1: 190.6, text: "да, слушаю"),
       #"{"ch":"them","label":"Иван Петров","t0":183.2,"t1":190.6,"text":"да, слушаю"}"#, "дроби")
    eq(LiveTranscript.encodeLine(ch: .me, label: "Я", t0: 190.0, t1: 195.0, text: "ок"),
       #"{"ch":"me","label":"Я","t0":190,"t1":195,"text":"ок"}"#, "целые без .0")
}

test("LiveTranscript: порядок по t0, хвосты, offset, id, файл") {
    let tmp = try makeTempDir()
    let file = tmp.appendingPathComponent("calls/2026-09-04_15-30-05/transcript.live.jsonl")
    let t = LiveTranscript(labels: [.me: "Я", .them: "Иван Петров"], fileURL: file)
    var changes = 0
    t.onChange = { changes += 1 }
    t.open(.me, offset: 0)
    t.open(.them, offset: 0)
    func phrase(_ n: Int, _ t0: Double, _ t1: Double, _ text: String) -> ChannelEvent {
        .phrase(ChannelPhrase(phrase: n, t0: t0, t1: t1, text: text, reason: "silence", windowSec: t1 - t0, decodes: 3))
    }

    t.apply(.them, .commit(phrase: 1, text: "Добрый"))
    t.apply(.them, .commit(phrase: 1, text: "день"))
    t.apply(.them, .preview(phrase: 1, text: "Иван"))
    eq(t.tails[.them], "Добрый день Иван", "хвост = коммиты через TextJoiner + preview")
    t.apply(.them, .commit(phrase: 1, text: ","))
    eq(t.tails[.them], "Добрый день, Иван", "знак препинания без пробела")
    t.apply(.them, .preview(phrase: 1, text: ""))
    eq(t.tails[.them], "Добрый день,", "пустой preview — только коммиты")

    t.apply(.them, phrase(1, 5.0, 9.5, "Добрый день, Иван"))
    check(t.tails[.them] == nil, "хвост очищен фразой")
    t.apply(.me, phrase(1, 3.2, 4.0, "Алло"))
    eq(t.lines.map(\.text), ["Алло", "Добрый день, Иван"], "me с t0=3.2 встал раньше them с t0=5.0")
    eq(t.lines.map(\.id), [2, 1], "id — порядок прихода")
    eq(t.lines[1].label, "Иван Петров", "метка канала")

    t.apply(.me, phrase(2, 5.0, 6.0, "Ага"))
    eq(t.lines.map(\.text), ["Алло", "Добрый день, Иван", "Ага"], "равный t0 — после существующих")
    t.apply(.me, phrase(3, 7.0, 7.5, ""))
    eq(t.lines.count, 3, "пустой текст не добавляется")

    // Перезапуск распознавателя: them открыт заново с offset 42 с (672 000 сэмплов уже в записи).
    t.apply(.them, .commit(phrase: 2, text: "хвост до перезапуска"))
    t.open(.them, offset: 42)
    check(t.tails[.them] == nil, "open очищает хвост")
    t.apply(.them, phrase(1, 0, 2.5, "после перезапуска"))
    let restarted = t.lines.last!
    eq(restarted.t0, 42, "t0 = offset + 0")
    eq(restarted.t1, 44.5, "t1 = offset + 2.5")
    eq(restarted.id, 4, "id монотонный при повторе (them, 1)")
    eq(Set(t.lines.map(\.id)).count, t.lines.count, "id уникальны")
    check(changes >= 10, "onChange звался на каждое событие")

    let text = try String(contentsOf: file, encoding: .utf8)
    let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
    eq(rows.count, 5, "ровно 4 строки + перевод строки в конце")
    eq(String(rows[0]), #"{"ch":"them","label":"Иван Петров","t0":5,"t1":9.5,"text":"Добрый день, Иван"}"#, "первая строка — порядок прихода")
    eq(String(rows[3]), #"{"ch":"them","label":"Иван Петров","t0":42,"t1":44.5,"text":"после перезапуска"}"#, "смещение в файле")

    let noFile = LiveTranscript(labels: [:], fileURL: nil)
    noFile.apply(.me, phrase(1, 0, 1, "без файла"))
    eq(noFile.lines.first?.label, "Я", "без метки — метка по умолчанию")
}

let callRecordExample = """
{
  "version": 1,
  "call_id": "2026-09-04_15-30-05",
  "started_at": "2026-09-04T15:30:05+03:00",
  "ended_at": "2026-09-04T15:40:17+03:00",
  "duration_sec": 612.4,
  "mode": "vks",
  "brief": null,
  "devices": {
    "input": "MacBook Pro Microphone",
    "output": "AirPods Pro",
    "app": {"name": "zoom.us", "bundle_id": "us.zoom.xos", "pid": 4242}
  },
  "model": "rnnt",
  "channels": {"0": "Я", "1": "Собеседник"},
  "recording": "2026-09-04_15-30-05.m4a",
  "meeting_id": null
}

"""

func exampleCallRecord() -> CallRecord {
    var r = CallRecord(callID: "2026-09-04_15-30-05", startedAt: Date(timeIntervalSince1970: 1_788_525_005),
                       model: "rnnt", channels: ["0": "Я", "1": "Собеседник"])
    r.endedAt = Date(timeIntervalSince1970: 1_788_525_617)
    r.durationSec = 612.4
    r.inputDevice = "MacBook Pro Microphone"
    r.outputDevice = "AirPods Pro"
    r.app = CallRecord.App(name: "zoom.us", bundleID: "us.zoom.xos", pid: 4242)
    r.recording = "2026-09-04_15-30-05.m4a"
    return r
}

test("CallRecord: байты примера §3.2 в зоне +3 и круговой decode") {
    let plus3 = TimeZone(secondsFromGMT: 3 * 3600)!
    let record = exampleCallRecord()
    eq(String(decoding: record.encoded(timeZone: plus3), as: UTF8.self), callRecordExample, "пример байт в байт")
    eq(try CallRecord.decode(record.encoded(timeZone: plus3)), record, "круговой decode")
    eq(try CallRecord.decode(record.encoded(timeZone: TimeZone(secondsFromGMT: 0)!)), record, "смещение +00:00 читается")

    var fresh = CallRecord(callID: "2026-09-04_15-30-05", startedAt: Date(timeIntervalSince1970: 1_788_525_005),
                           model: "rnnt", channels: ["0": "Я", "1": "Собеседник"])
    fresh.brief = "тема"
    let text = String(decoding: fresh.encoded(timeZone: plus3), as: UTF8.self)
    check(text.contains("  \"ended_at\": null,\n  \"duration_sec\": null,\n"), "до «Стоп» — null")
    check(text.contains("    \"app\": null\n"), "без звука приложения — null")
    check(text.contains("  \"brief\": \"тема\",\n"), "бриф")
    check(text.contains("  \"recording\": null,\n  \"meeting_id\": null\n}\n"), "хвост")
    eq(try CallRecord.decode(fresh.encoded(timeZone: plus3)), fresh, "круговой decode без необязательных полей")

    let unknown = Data(callRecordExample.replacingOccurrences(of: "\"meeting_id\": null", with: "\"meeting_id\": \"044d\",\n  \"cost\": 1.5").utf8)
    eq(try CallRecord.decode(unknown).meetingID, "044d", "неизвестные ключи игнорируются")
    check((try? CallRecord.decode(Data(callRecordExample.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2").utf8))) == nil, "version 2 отвергнут")
    check((try? CallRecord.decode(Data("мусор".utf8))) == nil, "не JSON — отвергнут")
}

test("CallStore: write/read/list и meeting_id из .meta.json") {
    let tmp = try makeTempDir()
    let root = tmp.appendingPathComponent("calls")
    eq(CallStore.defaultRoot(home: URL(fileURLWithPath: "/Users/x")).path, "/Users/x/ASR/Prompter/calls", "корень по умолчанию")
    eq(CallStore.folder(root: root, callID: "a").lastPathComponent, "a", "папка звонка")
    eq(CallStore.list(root: root).count, 0, "нет корня — пусто")

    let older = exampleCallRecord()
    var newer = CallRecord(callID: "2026-09-05_10-00-00", startedAt: Date(timeIntervalSince1970: 1_788_591_600),
                           model: "rnnt", channels: ["0": "Я", "1": "Собеседник"])
    newer.meetingID = "уже"
    let oldest = CallRecord(callID: "2026-08-01_09-00-00", startedAt: Date(timeIntervalSince1970: 1_785_567_600),
                            model: "rnnt", channels: ["0": "Я", "1": "Собеседник"])
    try CallStore.write(older, root: root)
    try CallStore.write(newer, root: root)
    try CallStore.write(oldest, root: root)
    try "x".write(to: root.appendingPathComponent("мусор.txt"), atomically: true, encoding: .utf8)
    let files = try FileManager.default.contentsOfDirectory(atPath: CallStore.folder(root: root, callID: older.callID).path)
    eq(files, ["call.json"], "временный файл не остался")
    eq(CallStore.read(root: root, callID: older.callID), older, "read")
    check(CallStore.read(root: root, callID: "нет") == nil, "read несуществующего — nil")
    eq(CallStore.list(root: root).map(\.callID), [newer.callID, older.callID, oldest.callID], "по startedAt убыв.")

    var changed = older
    changed.recording = nil
    try CallStore.write(changed, root: root)
    eq(CallStore.read(root: root, callID: older.callID), changed, "перезапись поверх")

    let output = tmp.appendingPathComponent("AllOutputs")
    let sep = output.appendingPathComponent("2026-09")
    try FileManager.default.createDirectory(at: sep, withIntermediateDirectories: true)
    try #"{"meeting_id": "044d", "source": "mlaud"}"#.write(to: sep.appendingPathComponent("2026-09-04_15-30-05.meta.json"), atomically: true, encoding: .utf8)
    try #"{"source": "mlaud"}"#.write(to: sep.appendingPathComponent("2026-09-05_10-00-00.meta.json"), atomically: true, encoding: .utf8)
    eq(CallStore.reconcileMeetingIDs(root: root, outputRoot: output), [older.callID], "дописан только тот, у кого появился meeting_id")
    eq(CallStore.read(root: root, callID: older.callID)?.meetingID, "044d", "meeting_id в call.json")
    eq(CallStore.read(root: root, callID: newer.callID)?.meetingID, "уже", "существующий не тронут")
    check(CallStore.read(root: root, callID: oldest.callID)?.meetingID == nil, "без .meta.json — нет")
    eq(CallStore.reconcileMeetingIDs(root: root, outputRoot: output), [], "повторный прогон ничего не меняет")
}

test("AudioPCM: int16, моно из плоскостей, interleave, rms") {
    let frames = [Float](repeating: 0.25, count: 320)
    eq(AudioPCM.int16(fromFloat: frames).count, 640, "320 кадров → 640 байт")
    eq(samples16(AudioPCM.int16(fromFloat: [1.5, -1.5, 0.5, 0, -0.5])), [32767, -32768, 16384, 0, -16384], "clamp и масштаб")
    eq(samples16(AudioPCM.int16(fromFloat: [.nan, .infinity, -.infinity])), [0, 32767, -32768], "NaN → 0, ±inf зажимаются, без падения")
    let nanPlane: [Float] = [.nan, 0.5]
    eq(samples16(nanPlane.withUnsafeBufferPointer { AudioPCM.monoInt16(planes: [$0], frames: 2) }), [0, 16384], "NaN в плоскости SCK → 0")
    let a: [Float] = [0.5, 0.5, 1.0]
    let b: [Float] = [-0.5, 0.5, 0.0]
    let mono = a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in AudioPCM.monoInt16(planes: [pa, pb], frames: 3) } }
    eq(samples16(mono), [0, 16384, 16384], "среднее по плоскостям")
    let inter: [Float] = [0.5, -0.5, 0.25, 0.25]
    eq(samples16(inter.withUnsafeBufferPointer { AudioPCM.monoInt16(interleaved: $0, channels: 2) }), [0, 8192], "среднее по interleaved")
    eq(samples16(AudioPCM.interleave(left: pcm16([1, 2]), right: pcm16([3, 4]))), [1, 3, 2, 4], "interleave")
    eq(AudioPCM.rms(int16: Data()), 0, "пусто → 0")
    let amp: Float = 0.5
    let sine = (0..<16000).map { amp * sin(2 * .pi * 440 * Float($0) / 16000) }
    let rms = AudioPCM.rms(int16: AudioPCM.int16(fromFloat: sine))
    check(abs(rms - 0.7071 * amp) < 0.005, "rms синуса ≈ 0.707·A, получили \(rms)")
    check(abs(AudioPCM.rms(int16: pcm16([32767, -32768])) - 1) < 1e-4, "полная шкала → ≈1")
}

test("CallTracks: выравнивание по времени звонка, пары кадров, добивка") {
    let tracks = CallTracks()
    let chunk = pcm16([Int16](repeating: 7, count: 1600))   // 0.1 с
    let first = tracks.align(.them, pcm: chunk, at: 1.0)
    eq(first.count, 16000 * 2 + chunk.count, "первый кусок them в 1.0 с — 16000 нулей спереди")
    check(samples16(first.prefix(32000)).allSatisfy { $0 == 0 }, "спереди тишина")
    eq(samples16(first).last, 7, "звук на месте")
    eq(tracks.align(.them, pcm: chunk, at: 1.15).count, chunk.count, "в пределах tolerance ничего не вставляется")

    var me = Data()
    for i in 0..<20 { me = tracks.align(.me, pcm: chunk, at: Double(i + 1) * 0.1) }   // me до 2.0 с
    eq(me.count, chunk.count, "поток без дыр не дополняется")
    let afterHole = tracks.align(.me, pcm: chunk, at: 4.0)
    eq(afterHole.count, 32000 * 2 + chunk.count, "дыра 2 с после пересборки микрофона — 2 с нулей")

    let t2 = CallTracks()
    eq(t2.push(.me, pcm: pcm16([1, 2, 3])).count, 0, "без them кадров нет")
    eq(samples16(t2.push(.them, pcm: pcm16([10, 20]))), [1, 10, 2, 20], "пары, сколько есть в обеих очередях")
    eq(t2.samples(.me), 3, "отдано в push")
    eq(t2.samples(.them), 2, "отдано в push")
    eq(samples16(t2.push(.me, pcm: pcm16([4]))), [], "them пуст — ждём")
    eq(samples16(t2.finish()), [3, 0, 4, 0], "finish добивает короткую дорожку нулями")
    eq(t2.finish().count, 0, "повторный finish пуст")
}

test("CallTracks.catchUp: замершая дорожка добивается тишиной по тику, без двойной заливки") {
    let tracks = CallTracks()
    let chunk = pcm16([Int16](repeating: 7, count: 1600))   // 0.1 с
    eq(tracks.catchUp(.them, to: 0.3).count, 0, "раньше tolerance — нечего добивать")
    var drained = 0
    for i in 0..<10 {   // me идёт 0.1…1.0 с, them молчит
        drained += tracks.push(.me, pcm: tracks.align(.me, pcm: chunk, at: Double(i + 1) * 0.1)).count
    }
    eq(drained, 0, "без them ничего не слито")
    eq(tracks.catchUp(.me, to: 1.0).count, 0, "живая дорожка не трогается")
    let fill = tracks.catchUp(.them, to: 1.0)
    eq(fill.count, 8000 * 2, "them отстал на 1.0 с — нули до elapsed − tolerance")
    check(samples16(fill).allSatisfy { $0 == 0 }, "заливка — тишина")
    eq(tracks.push(.them, pcm: fill).count, 8000 * 4, "после заливки слито 0.5 с стерео")
    eq(tracks.samples(.them), 8000, "заливка учтена в samples — offset для open согласован")
    eq(tracks.catchUp(.them, to: 1.0).count, 0, "повторный catchUp в тот же момент пуст")
    let resumed = tracks.align(.them, pcm: chunk, at: 1.05)
    eq(resumed.count, 8800 * 2 + chunk.count, "звук вернулся: дозаливка только 0.55 с, не 1.05 — голова уже сдвинута")
    eq(tracks.push(.them, pcm: resumed).count, 8000 * 4, "слито ровно то, что накопил me (0.5 с)")
    eq(tracks.finish().count, (8800 + 1600 - 8000) * 4, "finish добивает только хвост them, а не весь звонок")
}

test("AppAudioPolicy: таблица решений") {
    eq(AppAudioPolicy.classify(errorCode: -3801), .needsRestart, "−3801 — перезапуск")
    eq(AppAudioPolicy.classify(errorCode: -3802), .other(-3802), "иное — other")
    eq(AppAudioPolicy.afterOutputChange(lastBufferAge: nil), .restart, "буферов не было — restart")
    eq(AppAudioPolicy.afterOutputChange(lastBufferAge: 3), .restart, "встали дольше 2 с — restart")
    eq(AppAudioPolicy.afterOutputChange(lastBufferAge: 0.5), .keep, "идут — keep")
    eq(AppAudioPolicy.afterOutputChange(lastBufferAge: 5, stallTimeout: 10), .keep, "порог настраиваемый")
    eq(AppAudioPolicy.health(rms: 0.1, silentFor: 0), .flowing, "звук есть")
    eq(AppAudioPolicy.health(rms: 0.001, silentFor: 5), .flowing, "тихо, но недолго")
    eq(AppAudioPolicy.health(rms: 0.001, silentFor: 12), .silent(since: 12), "тихо дольше 10 с")
    eq(AppAudioPolicy.health(rms: 0.1, silentFor: 12), .flowing, "звук вернулся — flowing")
}

test("OutputDevice: эвристика динамиков и опрос CoreAudio без падения") {
    let builtIn = UInt32(kAudioDeviceTransportTypeBuiltIn)
    check(OutputDevice.isLikelySpeakers(transport: builtIn, dataSource: "Internal Speakers"), "встроенные динамики")
    check(!OutputDevice.isLikelySpeakers(transport: builtIn, dataSource: "Headphones"), "наушники в разъёме")
    check(!OutputDevice.isLikelySpeakers(transport: builtIn, dataSource: "Наушники"), "локализованный источник")
    check(!OutputDevice.isLikelySpeakers(transport: UInt32(kAudioDeviceTransportTypeBluetooth), dataSource: nil), "bluetooth — не динамики")
    check(!OutputDevice.isLikelySpeakers(transport: nil, dataSource: nil), "неизвестный транспорт — не пугаем")
    check(OutputDevice.isLikelySpeakers(transport: builtIn, dataSource: nil), "встроенный без источника — динамики")
    guard let device = OutputDevice.defaultDevice() else {
        check(false, "устройство вывода по умолчанию не определилось"); return
    }
    let name = OutputDevice.name(device)
    check(!name.isEmpty && !name.hasPrefix("устройство "), "имя настоящее: \(name)")
    let transport = OutputDevice.transportType(device)
    let source = OutputDevice.dataSourceName(device)
    check(transport != nil, "транспорт читается")
    print("    (текущий вывод: \(name), транспорт \(transport ?? 0), источник \(source ?? "—"), динамики: \(OutputDevice.likelySpeakers()))")
    let watch = OutputDeviceWatch(onChange: {})
    watch.start(); watch.stop(); watch.stop()
}

test("RecordingIndex: имена говорящих звонка — из channels.json архива (D14)") {
    let tmp = try makeTempDir()
    let root = tmp.appendingPathComponent("AllOutputs")
    let archive = tmp.appendingPathComponent("Processed/AllRecords")
    let speakers = tmp.appendingPathComponent("speakers")
    let fm = FileManager.default
    func put(_ dir: URL, _ name: String, _ text: String = "x") throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let sep = root.appendingPathComponent("2026-09")
    try put(sep, "2026-09-04_15-30-05.txt")
    try put(sep, "rec.txt")
    try put(sep, "битый.txt")
    let arch = archive.appendingPathComponent("2026-09")
    try put(arch, "2026-09-04_15-30-05.m4a")
    try put(arch, "2026-09-04_15-30-05.channels.json",
            String(decoding: ChannelsSidecar(callID: "2026-09-04_15-30-05", themLabel: "Иван Петров").encoded(), as: UTF8.self))
    try put(arch, "rec.m4a")
    try put(arch, "rec.channels.json",
            String(decoding: ChannelsSidecar(callID: "rec", themLabel: "Собеседник").encoded(), as: UTF8.self))
    try put(arch, "битый.channels.json", "{не json")
    try put(speakers.appendingPathComponent("2026-09/rec"), "speakers.json", sidecarJSON)

    let recs = RecordingIndex(root: root, speakersRoot: speakers, archiveRoot: archive).scan()
    let call = recs.first { $0.base == "2026-09-04_15-30-05" }!
    eq(call.speakers, ["Я", "Иван Петров"], "метки каналов вместо разметки")
    check(!call.needsLabeling, "разметка не нужна")
    check(!call.hasSidecar, "сайдкара разметки голосов нет")
    check(call.audio != nil, "аудио из архива")
    let rec = recs.first { $0.base == "rec" }!
    eq(rec.speakers, ["я", "Дина П(?)", "Спикер 4"], "speakers.json важнее channels.json")
    check(rec.hasSidecar, "сайдкар разметки есть")
    let broken = recs.first { $0.base == "битый" }!
    eq(broken.speakers, [], "битый channels.json — как без него")
    let withoutArchive = RecordingIndex(root: root, speakersRoot: speakers).scan()
    eq(withoutArchive.first { $0.base == "2026-09-04_15-30-05" }!.speakers, [], "без archiveRoot channels.json не читается")
}

// MARK: AgentAccess (MCP для внешних агентов)

test("AgentAccess: события процесса сервера") {
    eq(AgentAccess.Event.parse(line: #"{"t": "ready", "port": 8767}"#), .ready(port: 8767), "ready")
    eq(AgentAccess.Event.parse(line: #"{"t":"error","message":"порт 8767 занят"}"#),
       .error("порт 8767 занят"), "error")
    eq(AgentAccess.Event.parse(line: #"{"t":"ready","port":0}"#), nil, "порт 0 — не готов")
    eq(AgentAccess.Event.parse(line: #"{"t":"ready"}"#), nil, "без порта")
    eq(AgentAccess.Event.parse(line: "[mlaud-mcp] слушаю"), nil, "не JSON")
    eq(AgentAccess.Event.parse(line: #"{"t":"other"}"#), nil, "чужое событие")
}

test("AgentAccess: токен") {
    let a = AgentAccess.newToken(), b = AgentAccess.newToken()
    eq(a.count, 43, "32 байта в base64url без =")
    check(a != b, "токены случайны")
    check(AgentAccess.isValidToken(a), "свой токен валиден")
    check(!AgentAccess.isValidToken("short"), "короткий — нет")
    check(!AgentAccess.isValidToken(String(repeating: "a", count: 40) + "'x"), "кавычка ломала бы команду")
}

test("AgentAccess: токен создаётся один раз и меняется по запросу") {
    let store: SecretStore = InMemorySecretStore()
    let first = try AgentAccess.loadOrCreateToken(in: store)
    eq(try AgentAccess.loadOrCreateToken(in: store), first, "второй вызов — тот же токен")
    try store.setSecret("испорчен", for: AgentAccess.tokenAccount)
    let fixed = try AgentAccess.loadOrCreateToken(in: store)
    check(fixed != "испорчен" && AgentAccess.isValidToken(fixed), "испорченный заменён")
    let next = try AgentAccess.regenerateToken(in: store)
    check(next != fixed, "смена токена")
    eq(store.secret(for: AgentAccess.tokenAccount), next, "новый сохранён")
}

test("AgentAccess: команда openclaw и окружение") {
    let cmd = AgentAccess.openclawCommand(port: 8767, token: "TOKEN")
    eq(cmd, "openclaw mcp add mlaud --transport streamable-http --url http://127.0.0.1:8767/mcp"
        + " --header 'Authorization=Bearer TOKEN' --timeout 900", "команда")
    let env = AgentAccess.environment(port: 9000, token: "T")
    eq(env["MLAUD_MCP_PORT"], "9000", "порт")
    eq(env["MLAUD_MCP_TOKEN"], "T", "токен")
    eq(env["MLAUD_MCP_IDLE_SEC"], "600", "простой 10 минут")
}

test("AgentAccess: решение после выхода процесса") {
    eq(AgentAccess.afterExit(code: 2, lastError: "порт 8767 занят", failuresInLastMinute: 1),
       .fail("порт 8767 занят"), "ошибка конфигурации — без повторов")
    eq(AgentAccess.afterExit(code: 1, lastError: nil, failuresInLastMinute: 1),
       .restart(afterSeconds: 2), "упал — перезапуск")
    eq(AgentAccess.afterExit(code: -9, lastError: nil, failuresInLastMinute: 2),
       .restart(afterSeconds: 2), "второй раз — ещё перезапуск")
    if case .fail = AgentAccess.afterExit(code: 1, lastError: nil, failuresInLastMinute: 3) {} else {
        check(false, "третье падение за минуту — стоп")
    }
}

test("AgentAccess: состояние в меню") {
    eq(AgentAccess.State.listening(port: 8767).menuTitle, "Агенты (MCP): слушаю 127.0.0.1:8767", "меню")
}

test("SettingsStore: доступ агентов выключен по умолчанию, порт 8767") {
    let s = SettingsStore(defaults: makeDefaults())
    check(!s.agentAccessEnabled, "выключен")
    eq(s.agentAccessPort, 8767, "порт по умолчанию")
    s.agentAccessPort = 80
    eq(s.agentAccessPort, 8767, "привилегированный порт — к дефолту")
    s.agentAccessPort = 9100
    eq(s.agentAccessPort, 9100, "свой порт")
    s.agentAccessEnabled = true
    check(s.agentAccessEnabled, "включён")
    eq(s.workerEnvironment()["MLAUD_MCP_TOKEN"], nil, "токен не попадает в окружение пакетного worker'а")
}

removeTestDefaults()
runCallRecorderTests()
runOfflineTests()
runPrompterTests()
print("\n==== Swift tests: \(passed) passed, \(failed) failed ====")
exit(failed == 0 ? 0 : 1)
