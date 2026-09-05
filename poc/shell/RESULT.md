# S3 — оболочка: NitiUI на macOS и политика активации. Результат

**Дата:** 2026-09-05 · **Вопрос:** OQ-14 — переживает ли приложение переключение
`.accessory` ↔ `.regular` на лету, и что нужно пакету `NitiUI`, чтобы собраться на macOS.

**Вердикт: динамическая политика работает — 25 циклов из 25 без застреваний и без
«призраков» в обоих вариантах; `NitiUI` собирается на macOS после правок только в
`Tokens.swift` плюс hover в двух компонентах, публичные имена не тронуты, iOS-сборка
пакета зелёная.**

## (б) Политика активации

Проба `probe/main.swift` (`build_probe.sh`): бандл с `LSUIElement=true`, как у настоящего
приложения, запуск через `open`, главное меню установлено (без него у `.regular`-приложения
строка меню пустая, и это выглядело бы как искомый глюк). Цикл: `.regular` →
`activate(ignoringOtherApps:)` → окно ключевое → 0.5 с → окно спрятано → `.accessory` → 0.5 с.
Записываются четыре факта: активны ли мы и ключевое ли окно после `.regular`, активны ли мы
после `.accessory` (да = «призрак» с пустой строкой меню), кто спереди.

| вариант | циклов | застряло (не активны / окно не ключевое) | призраков |
|---|---|---|---|
| как есть (прогон 1, 20 циклов) | 20 | 1 — цикл 16, в этот момент пользователь переключился в другое приложение (спереди «Claude» с этого цикла и до конца) | 0 |
| с уступкой (прогон 1) | 20 | 1 — цикл 10: активны, но окно не успело стать ключевым за 0.5 с | 0 |
| **как есть (прогон 2, 25 циклов)** | 25 | **0** | **0** |
| **с уступкой (прогон 2)** | 25 | **0** | **0** |

«С уступкой» — перед уходом в `.accessory` активация отдаётся приложению, которое было
спереди до пробы (`yieldActivation(to:)`), а `activate` после `.regular` вызывается через
тик. Разницы нет: оба варианта чистые, а единичные сбои первого прогона объясняются
внешними событиями и на следующем цикле проходили сами — застревания, ради которого
затевалась проба (окно не становится ключевым, пока не переключишься в другое приложение
и обратно), нет.

Попутно: `activate(ignoringOtherApps: true)` на macOS 26.5 у приложения, запущенного через
`open`, срабатывает и когда спереди другое приложение — кооперативная активация 14+ его не
блокирует. В настоящем приложении активация к тому же идёт по клику в строке меню.

**Решение:** политика динамическая, как в ux-app.md §1: окно открыто → `.regular`
(иконка в Dock, строка меню), окно закрыто → `.accessory`. `LSUIElement=true` остаётся в
plist (старт без Dock). Главное меню обязательно (задача 1.3). Уступка активации не нужна.
UX-OQ-5 и OQ-14 закрыты.

## (а) `NitiUI` на macOS

`platforms: [.iOS(.v17), .macOS("15.0")]` (tools 5.10 — строкой). `swift build` дал ровно
ожидаемые ошибки — все в `Tokens.swift`, все про `UIColor`. Правки:

| место | что | как |
|---|---|---|
| `Color(light:dark:)` | динамический цвет через `UIColor { traits in … }` | `#if canImport(UIKit)` как было, `#else` — `NSColor(name: nil) { appearance in … }` по `bestMatch(from: [.aqua, .darkAqua])`, `Color(nsColor:)`; шестнадцатеричные значения — через `srgbRed:`, иначе калиброванный RGB даёт другой оттенок |
| `Shadow.soft` / `.pop` | `UIColor.black.withAlphaComponent` по теме | тот же `Color(light:dark:)` с прозрачностью на тему (`lightAlpha:` / `darkAlpha:`) |
| `Typography` | системные стили iOS | `#if os(macOS)`: фиксированные 11/12/13/13/14sb/18/22, таймер 28 (ux-app.md §2.2); системные стили Mac не годятся: `subheadline` 11, `footnote` 10, `title2` 17 |
| `Layout.minTapTarget` | 44 | 28 на macOS; имя то же, `NitiButtonStyle` и `NitiIconButton` читают токен и следуют сами |
| `Layout` (только macOS) | — | добавлены `rowHeight` 42, `rowBarWidth` 3, `sidebarWidth` 220, `formLabelWidth` 180 |
| `NitiButtonStyle` | нет hover | `@State hovered` внутри `ButtonBody` + `.onHover`: plain → `hover`, primary → `accentStrong`, success/danger → их фон (`.btn:hover`) |
| `NitiCard` | нет hover | параметр `hoverable: Bool = false` (по умолчанию как было) → фон `cardPressed` = `--card-hover` |
| новое `Desktop.swift` (`#if os(macOS)`) | — | `NitiSidebar`, `NitiNavItem`, `NitiNavCaption`, `NitiNavSeparator`, `NitiRow`, `NitiRowSection`, `NitiTabs`, `NitiFormRow`, `NitiField`, `NitiKeyValue` — по `app.css` (`.sidebar`, `.nav-item`, `.nav-cap`, `.nav-sep`, `.trow`, `.tsec`, `.settings-tabs .tab`, `.compose-form`) |

Гейт: список конечен, публичные имена не тронуты (у `NitiCard` добавлен параметр с
умолчанием). Проверка не чтением, а сборкой: `swift build` (macOS) — зелёный;
`xcodebuild -scheme NitiUI -destination 'generic/platform=iOS Simulator' build` — `BUILD
SUCCEEDED`. Правки лежат в репозитории `mlaud mobile` незакоммиченными.

Что не сделано и делается по ходу этапов: `NitiSplitter` (этап 3), `NitiPromptCard`,
`NitiLevelMeter`, `NitiTimerLabel` (этапы 3–4), витрина macOS (задача 1.14).

## Воспроизведение

```bash
poc/shell/build_probe.sh 25            # проба активации, журнал ~/ASR/spikes/shell/probe.log
cd "../mlaud mobile/DesignSystem" && swift build && \
  xcodebuild -scheme NitiUI -destination 'generic/platform=iOS Simulator' build
```
