# MLaud — приложение (Swift)

Главное окно в дизайн-системе Niti плюс строка меню. Окно: сайдбар с разделами
(Обзор, Записи, Суфлёр, Голоса, Диктовка, iPhone, Уведомления, Настройки), экраны на SwiftUI
внутри AppKit-оболочки. Строка меню остаётся как статус и быстрые действия. Собрано на SwiftPM
(без Xcode-проекта), минимальная macOS — 15.0 (ADR-020).

## Структура

- `Sources/MLaudCore/` — тестируемая логика без UI:
  - `FolderStore`, `SettingsStore` — папка inbox и настройки (UserDefaults).
  - `InboxScanner` — готовые аудиофайлы в папке и те, что ещё едут из iCloud.
  - `WorkerCommand` — запуск `python -m mlaud_worker…` с окружением.
  - `ProcessingStatus`, `OverviewState` — состояние конвейера и правила показа Обзора.
  - `RecordingIndex` — архив транскриптов: `.meta.json`, дата из имени файла, сайдкары
    разметки голосов, итоги суфлёра.
  - `NotificationHistory`, `PhoneReceipts`, `SpeakerSidecar`, `VoiceListing` — журналы и сайдкары.
  - `AudioCapture`, `HotKey`, `TextInserter`, `DictationProtocol` — диктовка.
- `Sources/MLaudApp/` — оболочка и экраны:
  - `AppDelegate` — строка меню, процессы (worker, распознаватель, приём с iPhone), слежение
    за папкой; заполняет `AppModel` и исполняет `AppCommands` для экранов.
  - `MainWindowController` — окно + `NSHostingView`, главное меню. Приложение всегда в Dock;
    закрытие окна его не завершает, клик по иконке открывает окно снова.
  - `AppModel`, `SettingsModel` — наблюдаемое состояние; настройки применяются сразу,
    побочный эффект — по ключу (смена токена не перезапускает модель диктовки).
  - `Screens/` — экраны разделов и витрина компонентов (⌥-клик по «Настройки»).
  - `VoicesModel` + `VoicesRunner` — состояние раздела «Голоса» и запуск
    `python -m mlaud_worker.voices`; экран — `Screens/VoicesScreen.swift`, подписи и плашки —
    `VoicesPresentation` в Core (с тестами).
- `Sources/MLaudTests/` — тест-раннер без XCTest (XCTest нет в Command Line Tools). Свои
  домены defaults `mlaud.test.*` он сметает при старте и в конце: cfprefsd дописывает пустые
  plist уже после выхода процесса, так что до следующего прогона в `~/Library/Preferences`
  остаётся до десятка пустых файлов.
- Дизайн-система — общий пакет `NitiUI` из `../mlaud mobile/DesignSystem` (ADR-019).

## Сборка и запуск

```bash
swift build                 # собрать
swift run MLaudApp          # запустить (иконка в строке меню → «Открыть MLaud»)
swift run MLaudTests        # прогнать тесты
swift run MLaudApp --screenshot ~/ASR/spikes/ui-shots   # снимки всех разделов в обеих темах
./build-dmg.sh              # MLaud.app + MLaud.dmg с вложенным Python-окружением
```

Дымовая проверка раздела «Голоса» — реальный worker на копии сайдкаров во временном каталоге
(`assign --none` меняет файлы, поэтому не на `~/ASR/service/speakers`):

```bash
./smoke-voices.sh           # фикстура из двух записей + swift run MLaudApp --smoke-voices …
```

Сам режим: `swift run MLaudApp --smoke-voices <каталог speakers> <python> <каталог worker>
<каталог базы голосов>`. Ожидает в `<каталог speakers>/<период>/<запись>/speakers.json` хотя
бы один кластер «к разметке»; печатает состояние до и после «оставить без имени», рендер
экрана, переход из образца к карточке (и в другую запись с теми же метками) и выходит с 0,
если всё сошлось (2 — размечать было нечего).

Режим `--screenshot` не запускает слежение, диктовку и приём: рядом может работать
установленное приложение на той же папке. У dev-запуска свои defaults; папку для Обзора
можно подставить переменной `MLAUD_INBOX`. Dev-пути к Python и worker'у — `MLAUD_PY`,
`MLAUD_WORKER_DIR` (по умолчанию `poc/.venv` и `worker/` в репозитории).

## Строка меню

Статус · iPhone (если включён) · **Открыть MLaud** · Обработать сейчас ⌘R · Диктовка ·
Уведомления… · Настройки… ⌘, · Выход. Всё остальное — в окне (ux-app.md §5).
