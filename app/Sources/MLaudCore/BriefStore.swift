import Foundation

/// Сводка брифа для списка; lastCall — последний звонок по этому брифу.
public struct BriefSummary: Equatable, Sendable, Identifiable {
    public let slug: String
    public let title: String
    public let template: String
    public let mode: String
    public let expectedMin: Int
    public let prompter: Bool
    public let lastCall: Date?
    public var id: String { slug }

    public init(slug: String, title: String, template: String, mode: String, expectedMin: Int,
                prompter: Bool, lastCall: Date? = nil) {
        self.slug = slug
        self.title = title
        self.template = template
        self.mode = mode
        self.expectedMin = expectedMin
        self.prompter = prompter
        self.lastCall = lastCall
    }
}

/// Папка `briefs/`, шаблоны `templates/`, материалы брифа (FP §4.1–4.2).
public enum BriefStore {
    public static let templateSlugs = ["sale", "interview", "negotiation", "meeting", "custom"]

    /// Тексты шаблонов (§3.2): заготовка брифа + раздел «Дополнение к промту» для роли.
    /// `interview` байт в байт совпадает с `worker/tests/fixtures/brief/template-interview.md`.
    public static let templateTexts: [String: String] = [
        "sale": """
        ---
        title:
        template: sale
        mode: vks
        expected_min: 30
        counterpart:
        goal:
        agenda:
        prompter: on
        model: default
        ---

        ## Задача встречи
        Что продаём, кому и какой результат считаем успехом (встреча прошла не зря, если …).

        ## Собеседник
        Роль, чем отвечает, что уже знает о продукте, возможные возражения.

        ## Скрипт / методология
        1. Установить контакт и согласовать цель звонка.
        2. Вопросы про ситуацию клиента.
        3. Презентация под ситуацию.
        4. Возражения.
        5. Следующий шаг с датой.

        ## Учитывать / избегать
        Не называть цену до выяснения потребности; не обещать того, чего нет в продукте.

        ## Дополнение к промту
        Этапы продажи: контакт → выяснение → презентация → возражения → следующий шаг.
        Карточки строй по текущему этапу: что важнее всего — спросить, показать или закрыть на следующий шаг.
        """,
        "interview": """
        ---
        title:
        template: interview
        mode: vks
        expected_min: 60
        counterpart:
        goal:
        agenda:
        prompter: on
        model: default
        ---

        ## Задача встречи
        Что проверяем в кандидате и какое решение должно быть на выходе.

        ## Собеседник
        Позиция, опыт из резюме, на что смотреть особенно внимательно.

        ## Скрипт / методология
        Блоки интервью с планом по минутам; кейс-задача и что в ней оценивается.

        ## Учитывать / избегать
        Не оценивать «по впечатлению»; не затягивать блок; держать время на вопросы кандидата.

        ## Дополнение к промту
        Критерии оценки: профессиональный опыт, системность мышления, коммуникация, мотивация.
        В каждом ходе отмечай, какой критерий проверяется текущим блоком; в итогах оцени каждый
        критерий с вердиктом и цитатой-основанием из реплик кандидата.
        """,
        "negotiation": """
        ---
        title:
        template: negotiation
        mode: vks
        expected_min: 45
        counterpart:
        goal:
        agenda:
        prompter: on
        model: default
        ---

        ## Задача встречи
        О чём договариваемся и что считается приемлемым результатом.

        ## Собеседник
        Сторона переговоров, полномочия, интересы, чего боится.

        ## Скрипт / методология
        1. Интересы сторон: что каждому на самом деле нужно.
        2. Варианты соглашения и зоны уступок.
        3. Красные линии.
        4. Фиксация договорённостей.

        ## Учитывать / избегать
        Не торговаться по позициям; не соглашаться на первое встречное; фиксировать письменно.

        ## Дополнение к промту
        Держи в фокусе интересы, а не позиции: карточки — про вопросы, вскрывающие интересы,
        варианты взаимовыгодного решения и точки, где пора фиксировать договорённость.
        """,
        "meeting": """
        ---
        title:
        template: meeting
        mode: vks
        expected_min: 30
        counterpart:
        goal:
        agenda:
        prompter: on
        model: default
        ---

        ## Задача встречи
        Что должно быть решено к концу встречи.

        ## Собеседник
        Участники, роли, кто решает.

        ## Скрипт / методология
        Пункты повестки с планом по минутам; кто отвечает за каждый пункт.

        ## Учитывать / избегать
        Не уходить в обсуждение без решения; возвращать к пункту повестки.

        ## Дополнение к промту
        Следи за повесткой и временем: карточки — про следующий пункт, нерешённые вопросы
        и решения, которые пора зафиксировать.
        """,
        "custom": """
        ---
        title:
        template: custom
        mode: vks
        expected_min: 30
        counterpart:
        goal:
        agenda:
        prompter: on
        model: default
        ---

        ## Задача встречи

        ## Собеседник

        ## Скрипт / методология

        ## Учитывать / избегать
        """,
    ]

    private static func briefDir(_ paths: PrompterPaths, _ slug: String) -> URL {
        paths.briefs.appendingPathComponent(slug, isDirectory: true)
    }

    /// Посев пяти шаблонов при первом запуске; существующие файлы не перезаписывает (FR-12.3).
    public static func seedTemplates(paths: PrompterPaths, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: paths.templates, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.briefs, withIntermediateDirectories: true)
        for slug in templateSlugs {
            let target = paths.templates.appendingPathComponent("\(slug).md")
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try templateTexts[slug]!.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    /// Slug'и существующих шаблонов в фиксированном порядке.
    public static func templates(paths: PrompterPaths) -> [String] {
        templateSlugs.filter { FileManager.default.fileExists(atPath: paths.templates.appendingPathComponent("\($0).md").path) }
    }

    /// Текст шаблона без раздела «Дополнение к промту» — заготовка нового брифа.
    public static func templateBody(paths: PrompterPaths, slug: String) -> String? {
        guard var brief = try? BriefParser.parse(templateTexts[slug] ?? "") else { return nil }
        brief.sections[Brief.addendumSection] = nil
        return BriefParser.encode(brief)
    }

    /// Slug из названия: латиница/цифры/дефис + дата; пусто → "brief-…".
    public static func slug(for title: String, now: Date) -> String {
        var latin = ""
        for ch in title.lowercased() {
            if let mapped = translit[ch] { latin += mapped; continue }
            if ch.isLetter || ch.isNumber { latin.append(ch) }
            else { latin.append("-") }
        }
        var base = latin.map { $0 == "-" ? "-" : $0 }
            .reduce(into: "") { partial, ch in
                if ch == "-", partial.hasSuffix("-") { return }
                partial.append(ch)
            }
        while base.hasSuffix("-") { base.removeLast() }
        if base.isEmpty { base = "brief" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(base)-\(f.string(from: now))"
    }

    private static let translit: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh",
        "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
        "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
        "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]

    /// Новый бриф из шаблона: копия заготовки без «Дополнения», title задан, materials/ создана.
    @discardableResult
    public static func newBrief(paths: PrompterPaths, template: String, title: String) throws -> String {
        var brief = try BriefParser.parse(templateTexts[template] ?? templateTexts["custom"]!)
        brief.title = title
        brief.sections[Brief.addendumSection] = nil
        let slug = slug(for: title, now: Date())
        let dir = briefDir(paths, slug)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("materials", isDirectory: true),
                                                withIntermediateDirectories: true)
        try BriefParser.encode(brief).write(to: paths.brief(slug: slug), atomically: true, encoding: .utf8)
        return slug
    }

    public static func load(paths: PrompterPaths, slug: String) throws -> Brief {
        try BriefParser.parse(String(contentsOf: paths.brief(slug: slug), encoding: .utf8))
    }

    /// tmp + rename, как CallStore.write.
    public static func save(_ brief: Brief, paths: PrompterPaths, slug: String) throws {
        let target = paths.brief(slug: slug)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".brief.md.\(UUID().uuidString).tmp")
        try BriefParser.encode(brief).write(to: tmp, atomically: true, encoding: .utf8)
        guard rename(tmp.path, target.path) == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }

    /// Копия папки с материалами; title + " (копия)".
    @discardableResult
    public static func duplicate(paths: PrompterPaths, slug: String) throws -> String {
        var brief = try load(paths: paths, slug: slug)
        brief.title += " (копия)"
        let newSlug = Self.slug(for: brief.title, now: Date())
        try FileManager.default.copyItem(at: briefDir(paths, slug), to: briefDir(paths, newSlug))
        try save(brief, paths: paths, slug: newSlug)
        return newSlug
    }

    public static func delete(paths: PrompterPaths, slug: String) throws {
        try FileManager.default.removeItem(at: briefDir(paths, slug))
    }

    /// Копия файла в materials/; дубль имени → суффикс " (2)". Возвращает имя файла.
    @discardableResult
    public static func addMaterial(paths: PrompterPaths, slug: String, from url: URL) throws -> String {
        let dir = paths.materials(slug: slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = url.lastPathComponent
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            name = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
        }
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
        return name
    }

    public static func removeMaterial(paths: PrompterPaths, slug: String, name: String) throws {
        try FileManager.default.removeItem(at: paths.materials(slug: slug).appendingPathComponent(name))
    }

    /// Список брифов; lastCall — максимальный startedAt звонков с этим briefDir.
    public static func list(paths: PrompterPaths, calls: [CallRecord]) -> [BriefSummary] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: paths.briefs, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        return dirs.compactMap { dir -> BriefSummary? in
            let slug = dir.lastPathComponent
            guard let brief = try? load(paths: paths, slug: slug) else { return nil }
            let lastCall = calls.filter { $0.briefDir == slug }.map(\.startedAt).max()
            return BriefSummary(slug: slug, title: brief.title, template: brief.template,
                                mode: brief.mode, expectedMin: brief.expectedMin,
                                prompter: brief.prompter, lastCall: lastCall)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
