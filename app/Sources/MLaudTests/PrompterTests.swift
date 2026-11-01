import Foundation
import MLaudCore

/// Тесты этапа 4 «подсказчик» — Core-логика (бриф, шаблоны, протокол, политика, снимок).
func runPrompterTests() {
    let fixtures = URL(fileURLWithPath: #filePath)      // app/Sources/MLaudTests/PrompterTests.swift
        .deletingLastPathComponent()                    // MLaudTests
        .deletingLastPathComponent()                    // Sources
        .deletingLastPathComponent()                    // app
        .deletingLastPathComponent()                    // корень репо
        .appendingPathComponent("worker/tests/fixtures", isDirectory: true)

    func fixture(_ path: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(path), encoding: .utf8)
    }

    func fixtureLines(_ path: String) throws -> [String] {
        try fixture(path).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: 1-3. Brief: разбор, каноническая запись, ошибки

    test("Brief: разбор ok-full совпадает с фикстурой JSON") {
        let brief = try BriefParser.parse(fixture("brief/ok-full.md"))
        let expected = try JSONSerialization.jsonObject(
            with: Data(fixture("brief/ok-full.json").utf8)) as! [String: Any]
        eq(brief.title, expected["title"] as! String, "title")
        eq(brief.template, expected["template"] as! String, "template")
        eq(brief.mode, expected["mode"] as! String, "mode (комментарий срезан)")
        eq(brief.expectedMin, expected["expected_min"] as! Int, "expected_min")
        eq(brief.counterpart, expected["counterpart"] as! String, "counterpart")
        eq(brief.goal, expected["goal"] as! String, "goal")
        eq(brief.prompter, expected["prompter"] as! Bool, "prompter")
        eq(brief.model, expected["model"] as! String, "model")
        let agenda = expected["agenda"] as! [[String: Any]]
        eq(brief.agenda.count, agenda.count, "агенда: длина")
        for (got, want) in zip(brief.agenda, agenda) {
            eq(got.text, want["text"] as! String, "пункт")
            eq(got.planMin, want["plan_min"] as? Int, "план минут")
        }
        let sections = expected["sections"] as! [String: String]
        eq(brief.sections, sections, "разделы")
        check(brief.extra.isEmpty, "extra пуст")
        check(brief.extraSections.isEmpty, "extra_sections пуст")

        let minimal = try BriefParser.parse(fixture("brief/ok-minimal.md"))
        eq(minimal.title, "Короткий звонок", "minimal title")
        eq(minimal.template, "custom", "minimal template по умолчанию")
        eq(minimal.expectedMin, 60, "minimal expected_min по умолчанию")
        check(!minimal.prompter, "minimal prompter по умолчанию off")
        check(minimal.agenda.isEmpty, "minimal agenda пуста")
    }

    test("Brief: encode → canonical байт в байт; круговой стабилен") {
        for name in ["ok-full", "ok-minimal"] {
            let text = try fixture("brief/\(name).md")
            let canonical = try fixture("brief/\(name).canonical.md")
            let once = BriefParser.encode(try BriefParser.parse(text))
            eq(once, canonical, "\(name): первый проход")
            let twice = BriefParser.encode(try BriefParser.parse(once))
            eq(twice, canonical, "\(name): второй проход")
            eq(BriefParser.encode(try BriefParser.parse(twice)), canonical, "\(name): третий проход")
        }
    }

    test("Brief: ошибки") {
        do {
            _ = try BriefParser.parse(fixture("brief/bad-mode.md"))
            check(false, "bad-mode должен падать")
        } catch let e as BriefParser.Failure {
            check(e == .badMode("phone"), "badMode(phone), получили \(e)")
        } catch {
            check(false, "не тот тип ошибки: \(error)")
        }
        do {
            _ = try BriefParser.parse(fixture("brief/bad-no-frontmatter.md"))
            check(false, "без фронт-маттера должен падать")
        } catch let e as BriefParser.Failure {
            check(e == .noFrontMatter, "noFrontMatter")
        } catch {
            check(false, "не тот тип ошибки: \(error)")
        }
        do {
            _ = try BriefParser.parse("---\ntitle: X\nmode: vks\nexpected_min: abc\n---\n")
            check(false, "expected_min: abc должен падать")
        } catch let e as BriefParser.Failure {
            check(e == .badValue(key: "expected_min", line: 4), "badValue с номером строки, получили \(e)")
        } catch {
            check(false, "не тот тип ошибки: \(error)")
        }
    }

    test("Brief: неизвестные ключи и разделы переживают круг") {
        let source = """
        ---
        title: T
        trello: board-42
        mode: vks
        ---
        ## Собеседник
        Кто это.

        ## Свой раздел
        Свой текст.
        """
        var brief = try BriefParser.parse(source)
        eq(brief.extra, [BriefField(key: "trello", value: "board-42")], "неизвестный ключ сохранён")
        eq(brief.extraSections.count, 1, "неизвестный раздел сохранён")
        let encoded = BriefParser.encode(brief)
        brief = try BriefParser.parse(encoded)
        eq(brief.extra, [BriefField(key: "trello", value: "board-42")], "ключ пережил круг")
        eq(brief.extraSections.first?.key, "Свой раздел", "раздел пережил круг")
        eq(brief.sections["Собеседник"], "Кто это.", "известный раздел на месте")
    }

    // MARK: 4. BriefStore

    test("BriefStore: seedTemplates создаёт пять файлов и не перезаписывает") {
        let tmp = try makeTempDir()
        let paths = PrompterPaths(root: tmp)
        try BriefStore.seedTemplates(paths: paths)
        eq(BriefStore.templates(paths: paths), ["sale", "interview", "negotiation", "meeting", "custom"], "все пять")
        // interview байт в байт равен общей фикстуре (Python-тест читает ту же).
        let seeded = try String(contentsOf: paths.templates.appendingPathComponent("interview.md"), encoding: .utf8)
        eq(seeded, try fixture("brief/template-interview.md"), "interview == фикстура")
        try "# правка пользователя".write(to: paths.templates.appendingPathComponent("interview.md"),
                                          atomically: true, encoding: .utf8)
        try BriefStore.seedTemplates(paths: paths)
        let after = try String(contentsOf: paths.templates.appendingPathComponent("interview.md"), encoding: .utf8)
        eq(after, "# правка пользователя", "существующий шаблон не тронут")
    }

    test("BriefStore: newBrief из interview без «Дополнения», дубль имени, list, duplicate, delete") {
        let tmp = try makeTempDir()
        let paths = PrompterPaths(root: tmp)
        try BriefStore.seedTemplates(paths: paths)
        let slug = try BriefStore.newBrief(paths: paths, template: "interview", title: "Интервью — Петров")
        let brief = try BriefStore.load(paths: paths, slug: slug)
        eq(brief.title, "Интервью — Петров", "title задан")
        check(brief.sections[Brief.addendumSection] == nil, "«Дополнение к промту» нет")
        check(FileManager.default.fileExists(atPath: paths.materials(slug: slug).path), "materials/ создана")
        check(slug.hasPrefix("intervyu-petrov-"), "slug из транслита и даты: \(slug)")

        let url = fixtures.appendingPathComponent("materials/note.md")
        eq(try BriefStore.addMaterial(paths: paths, slug: slug, from: url), "note.md", "материал скопирован")
        eq(try BriefStore.addMaterial(paths: paths, slug: slug, from: url), "note (2).md", "дубль имени → суффикс")

        var call = CallRecord(callID: "2026-09-04_15-30-05", startedAt: Date(timeIntervalSince1970: 1000),
                              model: "rnnt", channels: [:])
        call.briefDir = slug
        let list = BriefStore.list(paths: paths, calls: [call])
        eq(list.count, 1, "один бриф в списке")
        eq(list.first?.lastCall, call.startedAt, "lastCall по звонку")

        let copy = try BriefStore.duplicate(paths: paths, slug: slug)
        let copied = try BriefStore.load(paths: paths, slug: copy)
        eq(copied.title, "Интервью — Петров (копия)", "title + (копия)")
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.materials(slug: copy).path).sorted()
        eq(names, ["note (2).md", "note.md"], "материалы продублированы")

        try BriefStore.delete(paths: paths, slug: copy)
        check(!FileManager.default.fileExists(atPath: paths.brief(slug: copy).path), "копия удалена")
    }

    test("BriefStore: slug(for:) — таблица") {
        let now = Date(timeIntervalSince1970: 1_788_600_900)   // 2026-09-05 в текущей зоне
        check(BriefStore.slug(for: "Интервью — Иван Петров", now: now).hasPrefix("intervyu-ivan-petrov-"), "транслит")
        check(BriefStore.slug(for: "Sale Call 2026", now: now).hasPrefix("sale-call-2026-"), "латиница")
        check(BriefStore.slug(for: "", now: now).hasPrefix("brief-"), "пусто → brief-")
        check(BriefStore.slug(for: "  ", now: now).hasPrefix("brief-"), "пробелы → brief-")
        check(BriefStore.slug(for: "Собеседник!", now: now).hasPrefix("sobesednik-"), "знаки срезаны")
    }

    // MARK: 5. MaterialsReport

    test("MaterialsReport: decode и estimateTokens") {
        let line = #"{"materials":[{"name":"резюме.pdf","kind":"pdf","tokens":2100,"warning":null},{"name":"скан.pdf","kind":"pdf","tokens":0,"warning":"нет текстового слоя, пропущен"}],"total":2100,"budget":120000,"over":[]}"#
        let report = try MaterialsReport.decode(Data(line.utf8))
        eq(report.materials.count, 2, "два материала")
        eq(report.materials[1].warning, "нет текстового слоя, пропущен", "warning")
        eq(report.total, 2100, "total")
        eq(report.budget, 120000, "budget")

        eq(MaterialsReport.estimateTokens("абв"), 1, "абв → 1")
        eq(MaterialsReport.estimateTokens(""), 0, "пусто → 0")
        let tokens = try JSONSerialization.jsonObject(
            with: Data(fixture("materials/tokens.json").utf8)) as! [String: Int]
        // Черновая оценка — только для .md/.txt (D4): извлечение прочих типов делает worker.
        for name in ["note.md", "note.txt"] {
            let text = try fixture("materials/\(name)")
                .trimmingCharacters(in: .whitespacesAndNewlines)   // Python extract делает .strip()
            eq(MaterialsReport.estimateTokens(text), tokens[name] ?? -1,
               "\(name): та же эвристика, что у worker")
        }
    }

    // MARK: 6. AgendaTimer

    test("AgendaTimer: 50/80/100 по elapsed, каждая один раз, текст «Не начаты»") {
        let agenda = [BriefAgendaEntry(text: "Знакомство", planMin: 5),
                      BriefAgendaEntry(text: "Кейс-задача", planMin: 20)]
        let timer = AgendaTimer(expectedMin: 60, agenda: agenda)
        timer.update(agenda: [AgendaItem(item: "Знакомство", status: .active)])
        eq(timer.dueCards(elapsed: 1799), [], "до половины — пусто")
        let half = timer.dueCards(elapsed: 1800)
        eq(half.map(\.id), ["t.50"], "половина")
        check(half[0].text.contains("Не начаты: Кейс-задача"), "не начатый пункт в тексте: \(half[0].text)")
        check(!half[0].text.contains("Знакомство,"), "начатый пункт не в списке")
        eq(timer.dueCards(elapsed: 1810), [], "повторно пусто")
        let rest = timer.dueCards(elapsed: 4000)
        eq(rest.map(\.id), ["t.80", "t.100"], "80 % и 100 % одной пачкой")
        check(rest[1].text.contains("Не закрыты"), "на 100 % — «Не закрыты»")

        let turnTimer = AgendaTimer(expectedMin: 60, agenda: [])
        check(turnTimer.isTimerTurn(elapsed: 300), "ход на 300 с")
        check(!turnTimer.isTimerTurn(elapsed: 300), "не дважды на том же elapsed")
        check(!turnTimer.isTimerTurn(elapsed: 400), "между интервалами — нет")
        check(turnTimer.isTimerTurn(elapsed: 600), "ход на 600 с")
        check(turnTimer.isTimerTurn(elapsed: 1800), "ход на 50 %")
        let plan = AgendaTimer.planText(agenda: agenda,
                                        statuses: [AgendaItem(item: "Знакомство", status: .active)],
                                        elapsed: 1800, expectedMin: 60)
        check(plan.hasPrefix("Прошло 30 из 60 мин."), "planText: время")
        check(plan.contains("- Знакомство — идёт (план 5 мин)"), "planText: статусы и план")
        check(plan.contains("- Кейс-задача — ждёт (план 20 мин)"), "planText: нетронутый пункт")
    }

    // MARK: 7. PrompterPolicy

    test("PrompterPolicy: startDecision таблицей; afterCrash; linesSince") {
        let defaults = makeDefaults()
        let store = LLMConnectionsStore(defaults: defaults)
        var withKey = false

        eq(PrompterPolicy.startDecision(brief: nil, connections: store, hasKey: { _ in true }), .off, "нет брифа → off")
        var brief = Brief(title: "X")
        eq(PrompterPolicy.startDecision(brief: brief, connections: store, hasKey: { _ in true }), .off, "prompter off в брифе → off")

        brief.prompter = true
        brief.model = "default"
        eq(PrompterPolicy.startDecision(brief: brief, connections: store, hasKey: { _ in false }),
           .disabled("нет ключа у подключения «DeepSeek V4 Flash (OpenRouter)»"), "default без ключа → disabled")
        let decision = PrompterPolicy.startDecision(brief: brief, connections: store, hasKey: { _ in true })
        guard case .start(let c)? = Optional(decision), c.model == "deepseek/deepseek-v4-flash" else {
            check(false, "default с ключом → start пресетом")
            return
        }
        withKey = true
        check(withKey, "ветка start достигнута")

        brief.model = "Нет такого"
        eq(PrompterPolicy.startDecision(brief: brief, connections: store, hasKey: { _ in true }),
           .disabled("подключение «Нет такого» не найдено"), "имя не найдено")

        brief.model = "GLM-5.3 Flash (OpenRouter)"
        eq(PrompterPolicy.startDecision(brief: brief, connections: store, hasKey: { id in id.isEmpty }),
           .disabled("нет ключа у подключения «GLM-5.3 Flash (OpenRouter)»"), "именованный без ключа")

        let now = Date()
        eq(PrompterPolicy.afterCrash(history: [], now: now), .restart(attempt: 1), "первое падение — рестарт")
        eq(PrompterPolicy.afterCrash(history: [now.addingTimeInterval(-10), now.addingTimeInterval(-5)], now: now),
           .restart(attempt: 3), "третий — ещё рестарт")
        eq(PrompterPolicy.afterCrash(history: [now.addingTimeInterval(-10), now.addingTimeInterval(-5), now.addingTimeInterval(-2)],
                                     now: now), .giveUp, "третий за окно → giveUp")
        eq(PrompterPolicy.afterCrash(history: [now.addingTimeInterval(-500), now.addingTimeInterval(-5)], now: now),
           .restart(attempt: 2), "старые падения за окном не считаются")

        let lines = [TranscriptLine(id: 1, ch: .me, label: "Я", t0: 0, t1: 1, text: "a"),
                     TranscriptLine(id: 2, ch: .them, label: "Он", t0: 1, t1: 2, text: "b"),
                     TranscriptLine(id: 3, ch: .them, label: "Он", t0: 2, t1: 3, text: "c")]
        eq(PrompterPolicy.linesSince(lines, lastSentID: nil).map(\.id), [1, 2, 3], "nil → все")
        eq(PrompterPolicy.linesSince(lines, lastSentID: 1).map(\.id), [2, 3], "только новые")
        eq(PrompterPolicy.linesSince(lines, lastSentID: 3).map(\.id), [], "новых нет")
    }

    test("PrompterPolicy: status(for:) по таблице §1.6") {
        eq(PrompterPolicy.status(for: .error(message: "ключ отвергнут", retryInSec: nil, fatal: true, turn: nil),
                                 current: .ready), .disabled("ключ отвергнут"), "fatal → disabled")
        eq(PrompterPolicy.status(for: .error(message: "5xx", retryInSec: 10, fatal: false, turn: 3),
                                 current: .ready), .retrying(message: "5xx", inSec: 10), "5xx → retrying")
        eq(PrompterPolicy.status(for: .waiting(reason: "rpm", sec: 12), current: .ready),
           .waiting(reason: "rpm", sec: 12), "waiting")
        eq(PrompterPolicy.status(for: .paused(reason: "cost_ceiling", costUSD: 0.051, ceilingUSD: 0.05),
                                 current: .requesting(turn: 3)), .pausedByCost(costUSD: 0.051, ceilingUSD: 0.05), "потолок")
        let usage = PrompterUsage()
        eq(PrompterPolicy.status(for: .cards(turn: 4, cards: [], agenda: [], questionPending: false,
                                             usage: usage, firstCardMs: nil, latencyMs: 0, costUSD: nil, costTotalUSD: 0),
                                 current: .retrying(message: "5xx", inSec: 10)), .ready, "cards снимает retrying")
        eq(PrompterPolicy.status(for: .warm(ok: true, ttftMs: 1900, message: nil), current: .warming), .ready,
           "прогрев прошёл → ready")
        check(PrompterPolicy.status(for: .warm(ok: false, ttftMs: nil, message: "сеть"), current: .warming) == nil,
              "прогрев не прошёл — статус не меняется")
        check(PrompterPolicy.status(for: .card(PromptCard(id: "3.1", type: .answer, priority: 1, text: "x"),
                                               turn: 3), current: .warming) == nil, "card статус не меняет")
        check(PrompterPolicy.status(for: .ready(contextTokens: 1, materials: [], warnings: [], profileEmpty: false),
                                    current: .starting) == nil, "ready событие — статус ставит контроллер")
    }

    // MARK: 8. Протокол байт в байт

    test("PrompterCommand.line() — строки фикстуры байт в байт") {
        let wire1 = LLMConnection.Wire(baseURL: "https://openrouter.ai/api/v1", model: "deepseek/deepseek-v4-flash",
                                       reasoning: .off, price: .init())
        let wire2 = LLMConnection.Wire(baseURL: "https://openrouter.ai/api/v1", model: "z-ai/glm-5.3-flash",
                                       reasoning: .effort("low"), price: .init(input: 0.5, output: 2, cached: 0.05))
        let wire3 = LLMConnection.Wire(baseURL: "http://127.0.0.1:8080", model: "qwen3",
                                       reasoning: .unspecified, price: .init())
        let commands: [PrompterCommand] = [
            .start(callDir: "/Users/x/ASR/Prompter/calls/2026-09-04_15-30-05",
                   briefDir: "/Users/x/ASR/Prompter/briefs/interview-ivan",
                   profile: "/Users/x/ASR/Prompter/profile.md",
                   templatesDir: "/Users/x/ASR/Prompter/templates",
                   mode: "vks", expectedMin: 60, connection: wire1,
                   limits: .init(rpm: 6, costCeilingUSD: 0.5, debounceSec: 2.5, warmEverySec: 240)),
            .start(callDir: "/c", briefDir: "/b", profile: "/p", templatesDir: "/t",
                   mode: "offline", expectedMin: 30, connection: wire2,
                   limits: .init(rpm: 3, costCeilingUSD: nil, debounceSec: 2.5, warmEverySec: 240)),
            .start(callDir: "/c", briefDir: "/b", profile: "/p", templatesDir: "/t",
                   mode: "vks", expectedMin: 60, connection: wire3,
                   limits: .init(rpm: 6, costCeilingUSD: 0.5, debounceSec: 2.5, warmEverySec: 240)),
            .turn(reason: .themPhrase, elapsedSec: 1830,
                  lines: [TranscriptLine(id: 1, ch: .them, label: "Иван", t0: 1822.4, t1: 1829.1, text: "Добрый день"),
                          TranscriptLine(id: 2, ch: .me, label: "Я", t0: 1810, t1: 1815.2, text: "Здравствуйте")],
                  agendaManual: [AgendaItem(item: "Кейс-задача", status: .done)], notes: ""),
            .pause(true),
            .detail(cardID: "3.1"),
            .finish(elapsedSec: 3540, notes: "заметка"),
            .quit,
        ]
        let expected = try fixtureLines("protocol/commands.jsonl")
        eq(commands.count, expected.count, "число строк фикстуры")
        for (command, line) in zip(commands, expected) {
            eq(command.line(), line, "байт в байт")
        }
    }

    test("PrompterEvent.parse — каждая строка фикстуры; неизвестный t → nil; null → nil") {
        let parsed = try fixtureLines("protocol/events.jsonl").map { PrompterEvent.parse(line: $0) }
        check(!parsed.contains { $0 == nil }, "все строки протокола разобраны")

        guard case .ready(let ctx, let materials, let warnings, let profileEmpty)? = parsed[0] else {
            check(false, "ready не разобрался"); return
        }
        eq(ctx, 31400, "context_tokens")
        eq(materials.count, 2, "materials")
        eq(materials[1].warning, "нет текстового слоя, пропущен", "warning материала")
        eq(warnings, ["скан.pdf: нет текстового слоя, пропущен"], "warnings")
        check(!profileEmpty, "profile_empty")

        guard case .warm(let ok, let ttft, let message)? = parsed[1] else { check(false, "warm ok"); return }
        check(ok, "warm ok")
        eq(ttft, 1900, "ttft")
        check(message == nil, "без message")
        guard case .warm(false, nil, "сеть недоступна")? = parsed[2] else { check(false, "warm fail"); return }

        guard case .card(let card, let turn)? = parsed[3] else { check(false, "card"); return }
        eq(card, PromptCard(id: "3.1", type: .answer, priority: 1, text: "Спроси про кейс", source: ""), "карточка")
        eq(turn, 3, "turn")

        guard case .cards(let cTurn, let cards, let agenda, let qPending, let usage, let firstMs, let latency,
                          let cost, let costTotal)? = parsed[4] else { check(false, "cards"); return }
        eq(cTurn, 3, "cards turn")
        eq(cards.count, 2, "cards")
        eq(cards[1].source, "резюме.pdf", "source карточки")
        eq(agenda, [AgendaItem(item: "Опыт: два кейса подробно", status: .active)], "agenda")
        check(qPending, "question_pending")
        eq(usage.cachedTokens, 33024, "cached_tokens")
        eq(firstMs, 3400, "first_card_ms")
        eq(latency, 5700, "latency_ms")
        eq(cost, 0.001, "cost_usd")
        eq(costTotal, 0.012, "cost_total_usd")

        guard case .detail(let cardID, let text)? = parsed[5] else { check(false, "detail"); return }
        eq(cardID, "3.1", "detail card_id")
        eq(text, "Подробнее: спроси про второй кейс и метрики.", "detail text")

        guard case .waiting("rpm", 12)? = parsed[6] else { check(false, "waiting"); return }
        guard case .paused(_, 0.051, 0.05)? = parsed[7] else { check(false, "paused"); return }

        guard case .outcome(let outcome, let msg, let oUsage, let oCost)? = parsed[8] else { check(false, "outcome"); return }
        eq(outcome?.goalResult, .partial, "goal_result")
        eq(outcome?.decisions, ["дойти до кейса во второй встрече"], "decisions")
        eq(outcome?.assessment.first?.criterion, "системность", "assessment")
        eq(outcome?.markdown, "", "markdown пуст до чтения файла")
        check(msg == nil, "ok без message")
        eq(oUsage?.promptTokens, 34000, "usage итогов")
        eq(oCost, 0.014, "cost_total_usd итогов")

        guard case .outcome(nil, "суфлёр выключен", nil, 0.012)? = parsed[9] else { check(false, "outcome fail"); return }

        guard case .error("модель ответила 5xx", 10, false, 3)? = parsed[10] else { check(false, "error retry"); return }
        guard case .error("нет ключа: MLAUD_LLM_KEY пуст", nil, true, nil)? = parsed[11] else { check(false, "error fatal"); return }

        check(PrompterEvent.parse(line: #"{"t":"незвестное"}"#) == nil, "неизвестный t → nil")
        check(PrompterEvent.parse(line: "не JSON") == nil, "не JSON → nil")
        check(PrompterEvent.parse(line: "Warning: library noise") == nil, "мусор stdout → nil")
        let nullCost = PrompterEvent.parse(line: #"{"t":"cards","turn":1,"cards":[],"agenda":[],"flags":{"question_pending":false},"usage":{"prompt_tokens":1,"completion_tokens":1,"cached_tokens":0,"reasoning_tokens":0},"first_card_ms":null,"latency_ms":5,"cost_usd":null,"cost_total_usd":0}"#)
        guard case .cards(_, _, _, _, _, let first, _, let cost, _)? = nullCost else { check(false, "null-cost cards"); return }
        check(cost == nil, "cost_usd null → nil")
        check(first == nil, "first_card_ms null → nil")
    }

    // MARK: 9. CallSession: события суфлёра

    test("CallSession: события суфлёра не меняют phase; порции, pinned, dismissed, time-карточки") {
        let session = CallSession(now: { Date(timeIntervalSince1970: 0) })
        session.apply(.prepare(callID: "c", title: "T"))
        session.apply(.checklist(microphone: .ok, appAudio: .ok))
        session.apply(.start)
        let phase = session.snapshot.phase

        session.apply(.prompter(.warming))
        session.apply(.prompterReady(contextTokens: 31400, warnings: [], profileEmpty: true,
                                     connectionName: "DeepSeek V4 Flash (OpenRouter)", briefTitle: "T"))
        eq(session.snapshot.phase, phase, "фаза не изменилась")
        eq(session.snapshot.prompter.status, .warming, "статус warming")
        check(session.snapshot.prompter.profileEmpty, "profile_empty")

        let a1 = PromptCard(id: "1.1", type: .answer, priority: 1, text: "a1")
        let a2 = PromptCard(id: "1.2", type: .ask, priority: 2, text: "a2")
        var usage = PrompterUsage()
        usage.cachedTokens = 100
        session.apply(.cards(turn: 1, cards: [a1, a2], agenda: [AgendaItem(item: "П1", status: .pending)],
                             questionPending: false, usage: usage, firstCardMs: 900, latencyMs: 2000, costTotalUSD: 0.001))
        session.apply(.pin("1.1"))
        eq(session.snapshot.prompter.pinned.map(\.id), ["1.1"], "закреплена")
        eq(session.snapshot.prompter.cards.map(\.id), ["1.2"], "переехала из cards")

        let b1 = PromptCard(id: "2.1", type: .fact, priority: 1, text: "b1")
        session.apply(.card(b1, turn: 2))          // стрим нового хода: порция очищена, pinned жив
        eq(session.snapshot.prompter.cards.map(\.id), ["2.1"], "новый ход очистил порцию")
        eq(session.snapshot.prompter.pinned.map(\.id), ["1.1"], "pinned остался")

        let t50 = PromptCard(id: "t.50", type: .time, priority: 1, text: "половина")
        session.apply(.timeCard(t50))
        let c1 = PromptCard(id: "3.1", type: .answer, priority: 1, text: "c1")
        session.apply(.cards(turn: 3, cards: [c1], agenda: [AgendaItem(item: "П1", status: .done)],
                             questionPending: true, usage: usage, firstCardMs: 800, latencyMs: 1500, costTotalUSD: 0.004))
        eq(session.snapshot.prompter.cards.map(\.id), ["t.50", "3.1"], "time-карточка пережила порцию")
        eq(session.snapshot.prompter.agenda, [AgendaItem(item: "П1", status: .done)], "повестка — изменения по item")
        check(session.snapshot.prompter.questionPending, "флаг")
        eq(session.snapshot.prompter.turns, 2, "ходы посчитаны")
        eq(session.snapshot.prompter.costUSD, 0.004, "стоимость — итог сессии")
        eq(session.snapshot.prompter.lastCachedTokens, 100, "кэш")

        session.apply(.dismissCard("3.1"))
        check(session.snapshot.prompter.cards.map(\.id) == ["t.50"], "карточка убрана")
        let c1again = PromptCard(id: "3.1", type: .answer, priority: 1, text: "c1 снова")
        session.apply(.cards(turn: 4, cards: [c1again], agenda: [], questionPending: false,
                             usage: usage, firstCardMs: nil, latencyMs: 1, costTotalUSD: 0.004))
        check(!session.snapshot.prompter.cards.contains { $0.id == "3.1" }, "dismissed не возвращается")

        session.apply(.detail(cardID: "3.1", text: "раскрытие"))
        eq(session.snapshot.prompter.details["3.1"], "раскрытие", "detail по id")
        session.apply(.agendaManual(item: "П1", status: .pending))
        eq(session.snapshot.prompter.agenda.first?.status, .pending, "ручной клик по чипу")
        session.apply(.note("заметка"))
        eq(session.snapshot.prompter.notes, ["заметка"], "заметка")

        session.apply(.outcome(CallOutcome(goalResult: .achieved, reason: "r", summary: "s")))
        eq(session.snapshot.prompter.outcomeState, .ready, "итоги готовы")
        eq(session.snapshot.phase, .running, "phase всё ещё running")
    }

    test("CallSession: stop → outcomeState .computing только при включённом суфлёре; dismiss сбрасывает") {
        let session = CallSession(now: { Date(timeIntervalSince1970: 0) })
        session.apply(.prepare(callID: "c", title: "T"))
        session.apply(.checklist(microphone: .ok, appAudio: .ok))
        session.apply(.start)
        session.apply(.prompter(.ready))
        session.apply(.note("x"))
        session.apply(.stop)
        eq(session.snapshot.prompter.outcomeState, .computing, "включён → итоги считаются")
        session.apply(.finalized(URL(fileURLWithPath: "/tmp/x.m4a")))
        session.apply(.dismiss)
        eq(session.snapshot.prompter, PrompterSnapshot(), "dismiss сбросил снимок суфлёра")

        let second = CallSession(now: { Date(timeIntervalSince1970: 0) })
        second.apply(.prepare(callID: "c2", title: "T"))
        second.apply(.checklist(microphone: .ok, appAudio: .ok))
        second.apply(.start)
        second.apply(.prompter(.disabled("нет ключа")))
        second.apply(.stop)
        eq(second.snapshot.prompter.outcomeState, .none, "выключен → итоги не считаются")
    }

    // MARK: 10. CallRecord: добавления §3.5

    test("CallRecord: без полей этапа 4 байты прежние; с ними — ожидаемые; круговой decode") {
        let plus3 = TimeZone(secondsFromGMT: 3 * 3600)!
        let record = exampleCallRecord()
        eq(String(decoding: record.encoded(timeZone: plus3), as: UTF8.self), callRecordExample, "байты прежние")

        var stage4 = record

        stage4.briefDir = "interview-ivan"
        stage4.prompter = CallRecord.PrompterStats(
            enabled: true, connection: "DeepSeek V4 Flash (OpenRouter)", llmModel: "deepseek/deepseek-v4-flash",
            turns: 7, promptTokens: 236000, cachedTokens: 231000, completionTokens: 2100,
            costUSD: 0.012, firstCardMsMedian: 3400)
        stage4.goalResult = .partial
        let text = String(decoding: stage4.encoded(timeZone: plus3), as: UTF8.self)
        check(text.contains("  \"meeting_id\": null,\n  \"brief_dir\": \"interview-ivan\",\n"), "brief_dir после meeting_id")
        check(text.contains("  \"prompter\": {\"enabled\": true, \"connection\": \"DeepSeek V4 Flash (OpenRouter)\", \"llm_model\": \"deepseek/deepseek-v4-flash\", \"turns\": 7, \"prompt_tokens\": 236000, \"cached_tokens\": 231000, \"completion_tokens\": 2100, \"cost_usd\": 0.012, \"first_card_ms_median\": 3400},\n"), "блок prompter")
        check(text.contains("  \"outcome\": {\"goal_result\": \"partial\"}\n}\n"), "блок outcome и хвост")
        eq(try CallRecord.decode(stage4.encoded(timeZone: plus3)), stage4, "круговой decode с этапом 4")

        var partial = exampleCallRecord()
        partial.goalResult = .achieved
        let partialText = String(decoding: partial.encoded(timeZone: plus3), as: UTF8.self)
        check(partialText.contains("  \"meeting_id\": null,\n  \"outcome\": {\"goal_result\": \"achieved\"}\n}\n"),
              "только outcome — без brief_dir/prompter")
        eq(try CallRecord.decode(partial.encoded(timeZone: plus3)).goalResult, .achieved, "decode outcome")
    }

    // MARK: 11. LLMConnection, SettingsStore

    test("LLMConnection: пресеты, сериализация без ключа, store, connection(named:)") {
        eq(LLMConnection.presets.count, 2, "два пресета")
        eq(LLMConnection.presets[0].model, "deepseek/deepseek-v4-flash", "deepseek по умолчанию")
        eq(LLMConnection.presets[0].reasoning, .off, "рассуждения выключены")
        eq(LLMConnection.presets[1].reasoning, .effort("low"), "glm effort low")
        check(LLMConnection.presets.allSatisfy { $0.price.input == nil && $0.price.output == nil && $0.price.cached == nil },
              "пресеты без цен")

        var c = LLMConnection(name: "Мой", baseURL: "http://127.0.0.1:8080", model: "qwen3", reasoning: .unspecified)
        let data = try JSONEncoder().encode(c)
        let json = String(decoding: data, as: UTF8.self)
        check(!json.lowercased().contains("key") && !json.lowercased().contains("secret"),
              "в сериализации нет поля ключа: \(json)")
        check(!json.contains("sk-"), "нет значений ключей")
        c.reasoning = .off
        eq(c.wire.reasoning, .off, "wire повторяет рассуждения")
        eq(c.wire.baseURL, "http://127.0.0.1:8080", "wire base_url")

        let defaults = makeDefaults()
        let store = LLMConnectionsStore(defaults: defaults)
        eq(store.all.map(\.name), LLMConnection.presets.map(\.name), "пресеты посеяны при первом чтении")
        check(store.defaultConnection?.model == "deepseek/deepseek-v4-flash", "default — первый")
        store.save(c)
        check(store.connection(named: "Мой")?.model == "qwen3", "по имени")
        store.defaultID = c.id
        check(store.defaultConnection?.model == "qwen3", "default по id")
        store.remove(id: c.id)
        check(store.connection(named: "Мой") == nil, "удалено")
        check(store.defaultConnection?.model == "deepseek/deepseek-v4-flash", "default откатился к первому")
        let fresh = LLMConnectionsStore(defaults: defaults)
        eq(fresh.all.map(\.name), LLMConnection.presets.map(\.name), "персистентно и не сеется повторно")
    }

    test("SettingsStore: значения суфлёра по умолчанию и запись") {
        let settings = SettingsStore(defaults: makeDefaults())
        eq(settings.promptRPM, 6, "rpm 6")
        eq(settings.promptCostCeilingUSD, 0.50, "потолок 0.50")
        eq(settings.materialsBudgetTokens, 120_000, "бюджет 120k")
        check(!settings.compactPanelAtStart, "панель не открывается сама")

        settings.promptRPM = 12
        settings.promptCostCeilingUSD = 0.05
        settings.promptCostCeilingUSD = nil
        settings.materialsBudgetTokens = 5000
        settings.compactPanelAtStart = true
        eq(settings.promptRPM, 12, "rpm записан")
        check(settings.promptCostCeilingUSD == nil, "nil ↔ без потолка")
        eq(settings.materialsBudgetTokens, 5000, "бюджет записан")
        check(settings.compactPanelAtStart, "панель записана")
        check(!settings.workerEnvironment().keys.contains("MLAUD_LLM_KEY"), "ключ не попадает в workerEnvironment")
    }

    // MARK: 12. CallStore: файлы суфлёра

    test("CallStore: appendCard/readOutcome/writeOutcomeMarkdown на временном дереве") {
        let tmp = try makeTempDir()
        let root = tmp.appendingPathComponent("calls", isDirectory: true)
        CallStore.appendCard(root: root, callID: "2026-09-04_15-30-05",
                             line: #"{"turn":3,"elapsed_sec":1830,"at":"2026-09-04T16:00:35+03:00","card":{"id":"3.1","type":"answer","priority":1,"text":"x","source":""}}"#)
        CallStore.appendCard(root: root, callID: "2026-09-04_15-30-05",
                             line: #"{"turn":null,"elapsed_sec":1810,"at":"2026-09-04T16:00:15+03:00","card":{"id":"t.50","type":"time","priority":1,"text":"половина","source":""}}"#)
        let cards = try String(contentsOf: root.appendingPathComponent("2026-09-04_15-30-05/cards.jsonl"), encoding: .utf8)
        eq(cards.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2, "две строки в cards.jsonl")

        check(CallStore.readOutcome(root: root, callID: "2026-09-04_15-30-05") == nil, "без outcome.json — nil")
        let outcomeJSON = #"{"version":1,"call_id":"2026-09-04_15-30-05","outcome":{"goal_result":"partial","reason":"r","summary":"s","decisions":["d"],"next_steps":[],"open_questions":[],"assessment":[]},"usage":{},"cost_total_usd":0.014,"created_at":"x"}"#
        let dir = CallStore.folder(root: root, callID: "2026-09-04_15-30-05")
        try outcomeJSON.write(to: dir.appendingPathComponent("outcome.json"), atomically: true, encoding: .utf8)
        try "# Итоги\nтекст".write(to: dir.appendingPathComponent("outcome.md"), atomically: true, encoding: .utf8)
        let outcome = CallStore.readOutcome(root: root, callID: "2026-09-04_15-30-05")
        eq(outcome?.goalResult, .partial, "goal_result из outcome.json")
        eq(outcome?.decisions, ["d"], "decisions")
        eq(outcome?.markdown, "# Итоги\nтекст", "markdown из outcome.md")
        CallStore.writeOutcomeMarkdown(root: root, callID: "2026-09-04_15-30-05", text: "# Итоги\nправлено")
        eq(CallStore.readOutcome(root: root, callID: "2026-09-04_15-30-05")?.markdown, "# Итоги\nправлено", "перезапись итогов")

        CallStore.writeNotes(root: root, callID: "2026-09-04_15-30-05", notes: ["первая", "вторая"])
        eq(try String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8), "первая\nвторая\n", "notes.md")
    }
}
