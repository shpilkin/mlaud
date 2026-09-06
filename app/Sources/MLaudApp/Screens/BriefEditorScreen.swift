import MLaudCore
import NitiUI
import SwiftUI

/// Редактор брифа (UX:229-244): форма над моделью, сохранение с дебаунсом, без кнопки
/// «Сохранить»; материалы — отчёт процесса `--materials`, бюджет и over — баннером.
struct BriefEditorScreen: View {
    @Bindable var model: AppModel
    @State private var saveWork: DispatchWorkItem?

    var body: some View {
        Screen(model.editingBrief?.title.isEmpty == false ? model.editingBrief!.title : "Бриф",
               leading: { BackButton(label: "Суфлёр") { model.prompterView = .list } }) {
            if let brief = Binding($model.editingBrief) {
                briefForm(brief)
            } else {
                NitiEmptyState(systemImage: "doc.text", title: "Бриф не открыт",
                               message: "Выберите бриф в списке или создайте новый.")
            }
        } trailing: {
            if model.editingBriefSlug != nil {
                Button("Начать звонок") {
                    model.commands?.startCall(brief: model.editingBriefSlug!)
                }
                .buttonStyle(.nitiPrimary)
                Button("Дублировать") { model.commands?.duplicateBrief(slug: model.editingBriefSlug!) }
                    .buttonStyle(.niti(.plain, size: .small))
                Button("Папка") { model.commands?.openBriefFolder(slug: model.editingBriefSlug!) }
                    .buttonStyle(.niti(.plain, size: .small))
                Button("Удалить…") { model.commands?.deleteBrief(slug: model.editingBriefSlug!) }
                    .buttonStyle(.niti(.danger, size: .small))
            }
        }
    }

    @ViewBuilder
    private func briefForm(_ brief: Binding<Brief>) -> some View {
        NitiFormRow("Название") {
            TextField("", text: brief.title).textFieldStyle(.roundedBorder)
        }
        NitiFormRow("Шаблон") {
            Picker("", selection: brief.template) {
                ForEach(model.templates.isEmpty ? BriefStore.templateSlugs : model.templates, id: \.self) { slug in
                    Text(slug).tag(slug)
                }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 160)
        }
        NitiFormRow("Режим захвата") {
            Picker("", selection: brief.mode) {
                Text("ВКС (два канала)").tag("vks")
                Text("офлайн (один микрофон)").tag("offline")
            }
            .pickerStyle(.radioGroup)
        }
        NitiFormRow("Ожидаемая длительность, мин") {
            Stepper(value: brief.expectedMin, in: 5...480, step: 5) {
                Text("\(brief.wrappedValue.expectedMin)").font(Niti.Typography.base)
            }
        }
        NitiFormRow("Собеседник", hint: "до запятой — имя для подписи канала") {
            TextField("", text: brief.counterpart).textFieldStyle(.roundedBorder)
        }
        NitiFormRow("Цель") {
            TextField("", text: brief.goal, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
        }
        NitiFormRow("Повестка", hint: "пункт и план минут в скобках: «Кейс-задача (20)»") {
            VStack(alignment: .leading, spacing: Niti.Spacing.s2) {
                ForEach(brief.agenda.indices, id: \.self) { index in
                    HStack {
                        TextField("", text: brief.agenda[index].text).textFieldStyle(.roundedBorder)
                        TextField("мин", value: brief.agenda[index].planMin, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 54)
                        Button {
                            _ = withAnimation { brief.agenda.wrappedValue.remove(at: index) }
                            scheduleSave(brief)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.niti(.plain, size: .small))
                    }
                }
                Button {
                    withAnimation { brief.agenda.wrappedValue.append(BriefAgendaEntry(text: "", planMin: nil)) }
                    scheduleSave(brief)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.niti(.plain, size: .small))
            }
        }
        NitiFormRow("Суфлёр") {
            Toggle("Включён для этого брифа", isOn: brief.prompter).toggleStyle(.checkbox)
        }
        NitiFormRow("Модель", hint: "подключение из настроек; «default» — по умолчанию") {
            Picker("", selection: brief.model) {
                Text("default").tag("default")
                ForEach(model.settings.connections) { connection in
                    Text(connection.name).tag(connection.name)
                }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 260)
        }
        sectionEditor("Задача встречи", brief, key: "Задача встречи")
        sectionEditor("Собеседник", brief, key: "Собеседник")
        sectionEditor("Скрипт / методология", brief, key: "Скрипт / методология")
        sectionEditor("Учитывать / избегать", brief, key: "Учитывать / избегать")
        materialsSection
    }

    @ViewBuilder
    private func sectionEditor(_ title: String, _ brief: Binding<Brief>, key: String) -> some View {
        NitiFormRow(title) {
            TextEditor(text: Binding(
                get: { brief.wrappedValue.sections[key] ?? "" },
                set: { brief.wrappedValue.sections[key] = $0; scheduleSave(brief) }))
                .font(Niti.Typography.base)
                .frame(width: 380, height: 84)
                .border(Niti.Colors.border)
                .onChange(of: brief.wrappedValue.sections[key] ?? "") { scheduleSave(brief) }
        }
    }

    @ViewBuilder
    private var materialsSection: some View {
        NitiFormRow("Материалы", hint: "копии в папке брифа; токены — отчёт процесса") {
            VStack(alignment: .leading, spacing: Niti.Spacing.s2) {
                ForEach(model.editingMaterials?.materials ?? [], id: \.name) { material in
                    HStack(spacing: Niti.Spacing.s2) {
                        Image(systemName: "doc")
                        Text(material.name).lineLimit(1)
                        Text("\(material.kind)").foregroundStyle(Niti.Colors.muted)
                        if let warning = material.warning {
                            Text(warning).foregroundStyle(Niti.Colors.warning).lineLimit(1)
                        } else {
                            Text("\(material.tokens) ток.").foregroundStyle(Niti.Colors.subtle)
                        }
                        Spacer()
                        Button("−") { model.commands?.removeMaterial(slug: model.editingBriefSlug!, name: material.name) }
                            .buttonStyle(.niti(.plain, size: .small))
                    }
                    .font(Niti.Typography.sm)
                }
                HStack(spacing: Niti.Spacing.s2) {
                    Button("Добавить…") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let slug = model.editingBriefSlug {
                            model.commands?.addMaterials(slug: slug, urls: panel.urls)
                        }
                    }
                    .buttonStyle(.niti(.plain, size: .small))
                    Menu("Из записей…") {
                        ForEach(model.recordings.suffix(20).reversed().map { $0.base }, id: \.self) { base in
                            Button(base) {
                                model.commands?.addMaterialFromRecordings(slug: model.editingBriefSlug!, base: base)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    if let report = model.editingMaterials {
                        Text("бюджет \(report.total)/\(report.budget) ток.")
                            .font(Niti.Typography.sm)
                            .foregroundStyle(Niti.Colors.subtle)
                    }
                }
            }
        }
        if let report = model.editingMaterials, !report.over.isEmpty {
            NitiBanner("Не влезают в бюджет: \(report.over.joined(separator: ", ")) — уберите файлы или поднимите бюджет в настройках суфлёра.",
                       tone: .warn, systemImage: "exclamationmark.triangle")
        }
    }

    /// Дебаунс 0.5 с: правки пишутся в brief.md без кнопки (UX:231).
    private func scheduleSave(_ brief: Binding<Brief>) {
        saveWork?.cancel()
        let snapshot = brief.wrappedValue
        let work = DispatchWorkItem { model.commands?.saveBrief(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
