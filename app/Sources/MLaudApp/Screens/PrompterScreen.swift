import NitiUI
import SwiftUI

/// Раздел «Суфлёр»: брифы, звонки, итоги — этапы 3–4 плана. Пока — честное пустое состояние.
struct PrompterScreen: View {
    var body: some View {
        Screen("Суфлёр") {
            NitiEmptyState(systemImage: "text.bubble",
                           title: "Суфлёр ещё не собран",
                           message: "Брифы, живой звонок с подсказками и итоги — этапы 3–4 плана (docs/task-app-ui-and-prompter.md). Раздел зарезервирован.")
        }
    }
}
