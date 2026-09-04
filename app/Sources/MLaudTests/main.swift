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
    let store = SpeakerSidecarStore(root: root)
    let recent = store.recent()
    eq(recent.map { $0.sidecar.base }, ["rec", "rec"], "две записи, битая пропущена")
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

print("\n==== Swift tests: \(passed) passed, \(failed) failed ====")
exit(failed == 0 ? 0 : 1)
