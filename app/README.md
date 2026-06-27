# MLaud — приложение в строке меню (Swift)

Меню-бар приложение macOS: даёт выбрать папку inbox, следит за ней, при появлении аудио запускает
Python-worker (транскрипция GigaAM-v3 MLX), показывает статус. Собрано на SwiftPM (без Xcode-проекта).

## Структура

- `Sources/MLaudCore/` — тестируемая логика без UI:
  - `FolderStore` — хранит выбранную папку inbox (UserDefaults).
  - `InboxScanner` — готовые аудиофайлы в папке (зеркало логики worker'а: skip скрытых/`.icloud`/пустых).
  - `WorkerCommand` — построение запуска `python -m mlaud_worker` с `MLAUD_INBOX` = выбранная папка.
  - `ProcessingStatus` — состояния для меню.
- `Sources/MLaudApp/` — AppKit: `NSStatusItem`, меню, выбор папки (`NSOpenPanel`),
  пробуждение из сна (`NSWorkspaceDidWake`), периодический sweep, спавн worker'а.
- `Sources/MLaudTests/` — тест-раннер без XCTest (XCTest нет в Command Line Tools).

## Сборка и запуск

```bash
swift build                 # собрать
swift run MLaudApp          # запустить приложение (иконка появится в строке меню)
swift run MLaudTests        # прогнать тесты (26 проверок)
```

Dev-пути к Python/worker задаются через env `MLAUD_PY` и `MLAUD_WORKER_DIR`
(по умолчанию указывают на `poc/.venv` и `worker/` в репозитории).

## Меню

Статус · текущая папка · **Выбрать папку…** · Обработать сейчас · Открыть папку результатов · Выход.

> Сборка в `.dmg` и бандлинг Python-окружения внутрь .app — следующий шаг (требует упаковки venv,
> OQ-10). Сейчас приложение запускается из исходников через `swift run`.
