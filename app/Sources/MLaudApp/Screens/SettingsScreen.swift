import MLaudCore
import NitiUI
import SwiftUI

/// Настройки во вкладках; применение — сразу при изменении, предупреждения — баннером.
struct SettingsScreen: View {
    enum Tab: Hashable {
        case general, transcription, delivery, dictation, phone, prompter
    }

    @Bindable var model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        Screen("Настройки") {
            NitiTabs([
                .init(.general, "Общие", systemImage: "slider.horizontal.3"),
                .init(.transcription, "Транскрипция", systemImage: "waveform"),
                .init(.delivery, "Доставка", systemImage: "paperplane"),
                .init(.dictation, "Диктовка", systemImage: "mic"),
                .init(.phone, "iPhone", systemImage: "iphone"),
                .init(.prompter, "Суфлёр", systemImage: "text.bubble"),
            ], selection: Binding(
            get: { model.settingsTab },
            set: { model.settingsTab = $0 }))
            switch model.settingsTab {
            case .general: general
            case .transcription: transcription
            case .delivery: delivery
            case .dictation: dictation
            case .phone: phone
            case .prompter: prompter
            }
        }
        .onAppear { settings.refreshLoginItem() }
    }

    @ViewBuilder
    private var general: some View {
        @Bindable var settings = model.settings
        NitiFormRow("Папка inbox", hint: "откуда забирать аудио: iCloud, iPhone, руками") {
            HStack(spacing: Niti.Spacing.s2) {
                Text(model.overview.inboxPath ?? "не выбрана")
                    .font(Niti.Typography.base)
                    .foregroundStyle(model.overview.hasFolder ? Niti.Colors.text : Niti.Colors.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Выбрать…") { model.commands?.chooseFolder() }
                    .buttonStyle(.niti(.plain, size: .small))
            }
        }
        NitiFormRow("", hint: "реагировать на новый файл сразу; иначе проход раз в 120 с") {
            Toggle("Мгновенная обработка новых файлов", isOn: $settings.instantWatch)
                .toggleStyle(.checkbox)
        }
        NitiFormRow("", hint: "баннер в углу экрана; журнал в разделе «Уведомления» ведётся всегда") {
            Toggle("Системные уведомления о готовности и ошибке", isOn: $settings.notificationsEnabled)
                .toggleStyle(.checkbox)
        }
        NitiFormRow("", hint: "работает только для приложения в /Applications") {
            Toggle("Автозапуск при входе в систему",
                   isOn: Binding(get: { settings.loginItemEnabled }, set: { settings.setLoginItem($0) }))
                .toggleStyle(.checkbox)
        }
        if let error = settings.loginError {
            NitiBanner(error, tone: .warn, systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private var transcription: some View {
        @Bindable var settings = model.settings
        NitiFormRow("Модель", hint: "rnnt — точнее (рекомендуется); ctc — быстрее, чуть менее точно") {
            Picker("", selection: $settings.modelType) {
                ForEach(SettingsStore.availableModels, id: \.self) { Text($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 120)
        }
        NitiFormRow("", hint: "метки спикеров (pyannote); нужен HF-токен ниже") {
            Toggle("Диаризация — определять спикеров", isOn: $settings.diarizeEnabled)
                .toggleStyle(.checkbox)
        }
        if settings.diarizeWithoutToken {
            NitiBanner("Диаризация включена без HF-токена: файлы обработаются без меток спикеров.",
                       tone: .warn, systemImage: "exclamationmark.triangle")
        }
        NitiFormRow("HF-токен", hint: "для скачивания весов pyannote с huggingface.co; нужен один раз") {
            NitiField("hf_…", text: $settings.hfToken, secure: true)
                .frame(maxWidth: 360)
        }
        NitiFormRow("Число спикеров", hint: "0 — определить автоматически; N — если точно знаешь, сколько говорящих") {
            NitiField("0", text: Binding(
                get: { settings.numSpeakers > 0 ? String(settings.numSpeakers) : "" },
                set: { settings.numSpeakers = Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }))
                .frame(width: 80)
        }
        NitiFormRow("Устройство диаризации", hint: "mps — GPU Apple, в разы быстрее; cpu — запасной") {
            Picker("", selection: $settings.diarizeDevice) {
                ForEach(SettingsStore.availableDevices, id: \.self) { Text($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 120)
        }
        NitiFormRow("", hint: "имя вместо «Спикер N», если голос есть в базе; размечать — в разделе «Голоса»") {
            Toggle("Подписывать известные голоса", isOn: $settings.identifyEnabled)
                .toggleStyle(.checkbox)
                .disabled(!settings.diarizeEnabled)
        }
        NitiFormRow("Порог узнавания", hint: "строго — ни одного чужого имени на замере; мягко — больше имён, изредка чужое") {
            Picker("", selection: $settings.identifyPreset) {
                ForEach(SettingsStore.IdentifyPreset.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(!settings.diarizeEnabled)
            .frame(maxWidth: 360)
        }
    }

    @ViewBuilder
    private var delivery: some View {
        @Bindable var settings = model.settings
        NitiFormRow("Telegram токен", hint: "токен бота для доставки транскрипта файлом; пусто — берётся из .env worker'а") {
            NitiField("123456:ABC…", text: $settings.telegramToken, secure: true)
                .frame(maxWidth: 360)
        }
        NitiFormRow("Telegram chat_id", hint: "кому слать — твой chat id") {
            NitiField("напр. 123456789", text: $settings.telegramChatID)
                .frame(maxWidth: 200)
        }
        NitiFormRow("") {
            HStack(spacing: Niti.Spacing.s3) {
                Button("Проверить") { model.commands?.testTelegram() }
                    .buttonStyle(.niti)
                    .disabled(settings.telegramTest == .running)
                switch settings.telegramTest {
                case .idle: EmptyView()
                case .running: NitiStatusPill("отправляю…", tone: .accent)
                case .ok: NitiStatusPill("сообщение доставлено", tone: .success, systemImage: "checkmark")
                case .failed(let reason): NitiStatusPill(reason, tone: .danger, systemImage: "xmark")
                }
            }
        }
    }

    @ViewBuilder
    private var dictation: some View {
        @Bindable var settings = model.settings
        NitiFormRow("", hint: "наговорить текст прямо в активное поле ввода; спросит микрофон и «Универсальный доступ»") {
            Toggle("Диктовка по горячей клавише", isOn: $settings.dictationEnabled)
                .toggleStyle(.checkbox)
        }
        NitiFormRow("Сочетание клавиш", hint: "кликни и нажми нужное сочетание; Esc — отмена") {
            HotKeyRecorderView(combo: $settings.dictationHotKey)
                .frame(width: 160, height: 24)
        }
        NitiFormRow("Разрешения") {
            HStack(spacing: Niti.Spacing.s2) {
                NitiStatusPill(model.microphone == .authorized ? "микрофон есть" : "микрофон: нет",
                               tone: model.microphone == .authorized ? .success : .warning)
                NitiStatusPill(model.accessibilityTrusted ? "универсальный доступ есть" : "универсальный доступ: нет",
                               tone: model.accessibilityTrusted ? .success : .warning)
                Button("В раздел «Диктовка»") { model.section = .dictation }
                    .buttonStyle(.niti(.plain, size: .small))
            }
        }
    }

    /// Приложение звонка по умолчанию (ux-app.md §4.8 «Суфлёр: звук»). Кандидаты — только
    /// приложения с окнами (D17), список берётся по кнопке: запрос к системе показывает
    /// диалог «Запись экрана», дёргать его при каждом открытии настроек нельзя.
    @ViewBuilder
    private var prompter: some View {
        @Bindable var settings = model.settings
        NitiFormRow("Приложение звонка", hint: "звук собеседника берётся из этого приложения; выбор на экране звонка запоминается сюда") {
            HStack(spacing: Niti.Spacing.s2) {
                if model.callApps.isEmpty {
                    Text(settings.callAppBundleID ?? "не выбрано")
                        .font(Niti.Typography.base)
                        .foregroundStyle(settings.callAppBundleID == nil ? Niti.Colors.muted : Niti.Colors.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Picker("", selection: Binding<String?>(
                        get: { settings.callAppBundleID },
                        set: { settings.callAppBundleID = $0 })) {
                        Text("не выбрано").tag(String?.none)
                        ForEach(model.callApps) { app in
                            Text(app.name).tag(String?.some(app.bundleID))
                        }
                        if let current = settings.callAppBundleID,
                           !model.callApps.contains(where: { $0.bundleID == current }) {
                            Text(current).tag(String?.some(current))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 240)
                }
                Button("Обновить список") { model.commands?.refreshCallApps() }
                    .buttonStyle(.niti(.plain, size: .small))
                if settings.callAppBundleID != nil {
                    Button("Сбросить") { settings.callAppBundleID = nil }
                        .buttonStyle(.niti(.plain, size: .small))
                }
            }
        }
        NitiFormRow("Устройство ввода", hint: "микрофон по умолчанию из системных настроек звука; выбор на экране звонка — позже") {
            Text(model.call.inputDeviceName ?? "системное по умолчанию")
                .font(Niti.Typography.base)
                .foregroundStyle(Niti.Colors.subtle)
        }
        NitiFormRow("Звонок") {
            Button("В раздел «Суфлёр»") { model.section = .prompter }
                .buttonStyle(.niti(.plain, size: .small))
        }
        SettingsPrompterSection(model: model)
    }

    @ViewBuilder
    private var phone: some View {
        @Bindable var settings = model.settings
        NitiFormRow("", hint: "прямой приём по локальной сети — замена транзиту через iCloud") {
            Toggle("Принимать записи с iPhone", isOn: $settings.phoneSyncEnabled)
                .toggleStyle(.checkbox)
        }
        NitiFormRow("Код связи", hint: "QR-код и журнал принятого — в разделе «iPhone»") {
            Button("В раздел «iPhone»") { model.section = .phone }
                .buttonStyle(.niti(.plain, size: .small))
        }
    }
}

/// Профиль, подключения модели, лимиты подсказчика (FR-12.13/12.14, UX:364).
private struct SettingsPrompterSection: View {
    @Bindable var model: AppModel
    @State private var editing: LLMConnection?
    @State private var keyField = ""

    var body: some View {
        @Bindable var settings = model.settings
        NitiFormRow("Профиль", hint: "«кто я» — один файл, всегда в системном промте") {
            TextEditor(text: Binding(get: { settings.profileText },
                                     set: { settings.profileText = $0; model.commands?.saveProfile($0) }))
                .font(Niti.Typography.base)
                .frame(width: 320, height: 90)
                .border(Niti.Colors.border)
        }
        ForEach(settings.connections) { connection in
            NitiFormRow(connection.name, hint: "\(connection.baseURL) · \(connection.model) · рассуждения: \(reasoningLabel(connection))") {
                HStack(spacing: Niti.Spacing.s2) {
                    if settings.connectionHasKey[connection.id] == true {
                        Text("ключ: есть").font(Niti.Typography.sm).foregroundStyle(Niti.Colors.subtle)
                    }
                    if settings.defaultConnectionID == connection.id || settings.defaultConnectionID == nil {
                        Text("по умолчанию").font(Niti.Typography.sm).foregroundStyle(Niti.Colors.accent)
                    }
                    checkView(connection)
                    Button("Изменить…") { editing = connection; keyField = "" }
                        .buttonStyle(.niti(.plain, size: .small))
                    Button("По умолчанию") { model.commands?.setDefaultConnection(id: connection.id) }
                        .buttonStyle(.niti(.plain, size: .small))
                    Button("Удалить") { model.commands?.removeConnection(id: connection.id) }
                        .buttonStyle(.niti(.danger, size: .small))
                }
            }
        }
        NitiFormRow("Подключения") {
            Button("Добавить…") {
                editing = LLMConnection(name: "Новое подключение", baseURL: "https://openrouter.ai/api/v1",
                                        model: "", reasoning: .off)
                keyField = ""
            }
            .buttonStyle(.niti(.plain, size: .small))
        }
        NitiFormRow("Запросов в минуту", hint: "FR-12.14, не больше N ходов модели в минуту") {
            Stepper(value: $settings.promptRPM, in: 1...30) {
                Text("\(settings.promptRPM)").font(Niti.Typography.base)
            }
        }
        NitiFormRow("Потолок стоимости за звонок, $", hint: "пусто — без потолка; при превышении суфлёр на паузу, звонок продолжается") {
            TextField("", text: Binding(
                get: { settings.promptCostCeilingUSD.map { String($0) } ?? "" },
                set: { settings.promptCostCeilingUSD = Double($0.replacingOccurrences(of: ",", with: ".")) }))
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
        }
        NitiFormRow("Бюджет материалов, токенов", hint: "свыше — самые большие файлы в промт не идут (FR-12.5)") {
            TextField("", value: $settings.materialsBudgetTokens, formatter: NumberFormatter())
                .frame(width: 120)
                .textFieldStyle(.roundedBorder)
        }
        NitiFormRow("Компактная панель", hint: "плавающая полоска с карточками поверх Zoom (⌘⇧C)") {
            Toggle("Открывать при старте звонка", isOn: $settings.compactPanelAtStart)
                .toggleStyle(.checkbox)
        }
        .sheet(item: $editing) { connection in
            ConnectionEditor(model: model, connection: connection, keyField: $keyField)
        }
    }

    @ViewBuilder
    private func checkView(_ connection: LLMConnection) -> some View {
        switch model.settings.connectionCheck[connection.id] ?? .idle {
        case .idle:
            Button("Проверить") { model.commands?.checkConnection(id: connection.id) }
                .buttonStyle(.niti(.plain, size: .small))
        case .running:
            Text("проверяю…").font(Niti.Typography.sm).foregroundStyle(Niti.Colors.muted)
        case .ok(let ttft):
            Text("ок, первый токен \(ttft) мс").font(Niti.Typography.sm).foregroundStyle(Niti.Colors.success)
        case .failed(let message):
            Text(message).font(Niti.Typography.sm).foregroundStyle(Niti.Colors.danger).lineLimit(1)
        }
    }

    private func reasoningLabel(_ c: LLMConnection) -> String {
        switch c.reasoning {
        case .off: return "выключены"
        case .effort(let e): return "effort \(e)"
        case .unspecified: return "не задавать"
        }
    }
}

/// Редактор подключения: имя, шлюз, модель, рассуждения, цены, ключ (не хранится в модели).
private struct ConnectionEditor: View {
    let model: AppModel
    @State var connection: LLMConnection
    @Binding var keyField: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Niti.Spacing.s3) {
            Text("Подключение").font(Niti.Typography.base.weight(.semibold))
            labeled("Имя", TextField("", text: $connection.name).textFieldStyle(.roundedBorder))
            labeled("Шлюз (base_url)", TextField("", text: $connection.baseURL).textFieldStyle(.roundedBorder))
            labeled("Модель", TextField("", text: $connection.model).textFieldStyle(.roundedBorder))
            labeled("Рассуждения", Picker("", selection: $connection.reasoning) {
                Text("выключены").tag(LLMConnection.Reasoning.off)
                Text("effort low").tag(LLMConnection.Reasoning.effort("low"))
                Text("effort medium").tag(LLMConnection.Reasoning.effort("medium"))
                Text("не задавать").tag(LLMConnection.Reasoning.unspecified)
            }.pickerStyle(.menu).labelsHidden())
            labeled("Цена за 1M токенов, $ (пусто — из usage.cost шлюза)", HStack {
                priceField("вход", $connection.price.input)
                priceField("выход", $connection.price.output)
                priceField("кэш", $connection.price.cached)
            })
            SecureField("Ключ (пусто — не менять)", text: $keyField).textFieldStyle(.roundedBorder)
            HStack {
                Button("Сохранить") {
                    model.commands?.saveConnection(connection, key: keyField.isEmpty ? nil : keyField)
                    dismiss()
                }
                .buttonStyle(.nitiPrimary)
                Button("Отмена") { dismiss() }.buttonStyle(.niti(.plain))
            }
        }
        .padding(Niti.Spacing.s5)
        .frame(width: 460)
    }

    @ViewBuilder
    private func labeled(_ label: String, _ field: some View) -> some View {
        HStack {
            Text(label).font(Niti.Typography.sm).foregroundStyle(Niti.Colors.subtle).frame(width: 170, alignment: .leading)
            field
        }
    }

    private func priceField(_ label: String, _ price: Binding<Double?>) -> some View {
        TextField(label, text: Binding(
            get: { price.wrappedValue.map { String($0) } ?? "" },
            set: { price.wrappedValue = Double($0.replacingOccurrences(of: ",", with: ".")) }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
    }
}
