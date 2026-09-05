import MLaudCore
import NitiUI
import SwiftUI

/// Настройки во вкладках; применение — сразу при изменении, предупреждения — баннером.
struct SettingsScreen: View {
    enum Tab: Hashable {
        case general, transcription, delivery, dictation, phone
    }

    @Bindable var model: AppModel
    @State private var tab: Tab = .general

    var body: some View {
        @Bindable var settings = model.settings
        Screen("Настройки") {
            NitiTabs([
                .init(.general, "Общие", systemImage: "slider.horizontal.3"),
                .init(.transcription, "Транскрипция", systemImage: "waveform"),
                .init(.delivery, "Доставка", systemImage: "paperplane"),
                .init(.dictation, "Диктовка", systemImage: "mic"),
                .init(.phone, "iPhone", systemImage: "iphone"),
            ], selection: $tab)
            switch tab {
            case .general: general
            case .transcription: transcription
            case .delivery: delivery
            case .dictation: dictation
            case .phone: phone
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
