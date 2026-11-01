# MLaud Worker (Python)

Эфемерный обработчик: декодирует аудио, транскрибирует локально (GigaAM-v3 MLX, RNNT),
пишет `.txt`/`.srt` с тайм-кодами, доставляет в Telegram файлом, архивирует аудио.
Запускается Swift-приложением как подпроцесс (см. ../docs/architecture.md).

## Модули

- `audio.py` — декодирование без ffmpeg: `afconvert` (macOS) + `soundfile` + ресемплинг `soxr` до 16 кГц.
  ⚠️ Всегда читаем фактическую частоту и ресемплим (ADR-014; иначе баг 48к→мусор).
- `transcribe.py` — обёртка над `gigaam-mlx`: модель грузится один раз, ffmpeg-free загрузчик.
- `mlx_cache.py` — предел кэша MLX 1 ГБ, ставится до загрузки модели в `transcribe.py` и `dictate.py`.
  Без него MLX копит освобождённые буферы до 45.6 ГБ: ~29 ГБ на 18-минутной записи, 7 ГБ за 22 с диктовки.
- `output.py` — форматирование `.txt` (с тайм-кодами) и `.srt`.
- `telegram.py` — доставка файлом (`sendDocument`); sender инъектируется для тестов.
  `python -m mlaud_worker.telegram --test` — тестовое сообщение по `MLAUD_TG_TOKEN` /
  `MLAUD_TG_CHAT_ID` (кнопка «Проверить» в настройках приложения).
- `pipeline.py` — оркестрация inbox → транскрипция → вывод → доставка → архив; lock, идемпотентность.
- `diarize.py` — pyannote 3.1: интервалы спикеров + центроиды кластеров; наложение на слова, подписи.
- `spkid.py` — узнавание голоса, чистая математика: `match()` против галереи + правила файла
  (фильтр по речи, конфликт имён, полосы уверенности). Пороги — из замера, см. ADR-016.
- `voices.py` — база голосов `~/ASR/voices` (образцы по людям) и CLI: enrollment, разметка по
  сайдкару, переподпись, повторная отправка, переименование.
- `speakers.py` — сайдкар записи для окна «Голоса»: кластеры, цитаты, векторы, клипы по 6 с;
  переподпись `.txt`/`.srt`; ретенция 30 дней.
- `channels.py` — запись звонка Суфлёра: сайдкар `<call_id>.channels.json`, транскрипция стерео по дорожкам без диаризации (см. «Сайдкар каналов»).
- `dictate.py` — живое распознавание для диктовки и звонка: JSON-строки через stdin/stdout (см. «Протокол диктовки и каналов»).
- `config.py` — пути и параметры. `__main__.py` — CLI-вход.

## Установка (через uv, изолированно)

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python "git+https://github.com/aystream/gigaam-mlx.git" pytest
# soxr, soundfile, numpy, requests подтягиваются как зависимости gigaam-mlx
```

## Запуск

```bash
# пути и Telegram — через переменные окружения (иначе дефолтные пути ~/ASR и iCloud)
export MLAUD_TG_TOKEN=...        # от @BotFather (опционально)
export MLAUD_TG_CHAT_ID=...      # от @userinfobot (опционально)
.venv/bin/python -m mlaud_worker
```

Переменные: `MLAUD_INBOX`, `MLAUD_OUTPUT`, `MLAUD_PROCESSED`, `MLAUD_SERVICE`, `MLAUD_MODEL`
(`rnnt`/`ctc`), `MLAUD_TG_TOKEN`, `MLAUD_TG_CHAT_ID`; диаризация — `MLAUD_DIARIZE`,
`MLAUD_HF_TOKEN`, `MLAUD_DIARIZE_DEVICE`, `MLAUD_NUM_SPEAKERS`.

## Имена спикеров (голос-ID, Фаза 3)

Опция поверх диаризации: кластер сравнивается с базой голосов, и вместо «Спикер N» в
транскрипт идёт имя (`Имя`, при косинусе ниже 0.80 — `Имя(?)`). Кластер с речью короче
30 c имени не получает никогда. Пороги измерены на собственном архиве
([docs/adr.md](../docs/adr.md), ADR-016), пере-выводятся скриптами `../poc/spkid/`.

Переменные: `MLAUD_IDENTIFY=1`, `MLAUD_VOICES_DIR` (по умолчанию `~/ASR/voices`, локально,
не iCloud — это биометрия), `MLAUD_IDENTIFY_THRESHOLD` (0.80 строго / 0.75 баланс / 0.70 мягко),
`MLAUD_IDENTIFY_MIN_SPEECH` (30).

При включённой идентификации worker пишет для каждой записи сайдкар
`~/ASR/service/speakers/<YYYY-MM>/<base>/speakers.json` и клипы рядом — по ним окно «Голоса»
в приложении размечает спикеров без повторной диаризации. Приложение сайдкар только читает,
меняет его worker:

```bash
python -m mlaud_worker.voices import-eval [~/ASR/spkid-eval]   # разметка замера → база (без смесей и коротких)
python -m mlaud_worker.voices prepare <аудио из архива>…        # старая запись: транскрипт заново + сайдкар
python -m mlaud_worker.voices rematch [<…>]                      # пересчитать подсказки по текущей базе
python -m mlaud_worker.voices forget <…>                         # убрать запись из разметки (клипы, векторы)
python -m mlaud_worker.voices assign <каталог записи|speakers.json> "Спикер 2" --name "Милана Г" --channel phone
python -m mlaud_worker.voices assign <…> 3 --none        # оставить без имени (--mixed: смесь, --delete: корзина, --restore: вернуть)
python -m mlaud_worker.voices assign <…> 1 --reject      # автоузнавание неверно
python -m mlaud_worker.voices relabel <…>                # переписать .txt/.srt текущими именами
python -m mlaud_worker.voices resend <…>                 # отправить .txt в Telegram заново
python -m mlaud_worker.voices rename "Старое" "Новое"    # в базе и в сайдкарах
python -m mlaud_worker.voices list --json                # для приложения
```

Из аудио напрямую (без сайдкара) — нужен venv с pyannote (`../poc/.venv`):

```bash
# кто есть в файле и кого база узнаёт; «Спикер N» — как в транскрипте
../poc/.venv/bin/python -m mlaud_worker.voices show "запись.m4a"
# положить голос кластера в базу (кластер: «Спикер 2», 2 или SPEAKER_01)
../poc/.venv/bin/python -m mlaud_worker.voices enroll "запись.m4a" "Спикер 2" "Милана Г" --channel phone
../poc/.venv/bin/python -m mlaud_worker.voices list
../poc/.venv/bin/python -m mlaud_worker.voices remove --sample <id>     # или --person "Имя"
```

Образцы хранятся раздельно (телефон и ВКС различаются заметно) и усредняются только при
матчинге. Удаление человека удаляет и векторы, и метаданные.

## Протокол диктовки и каналов (`dictate.py`) — байт в байт

Транспорт как сейчас (`dictate.py:8-20`): JSON-строки в обе стороны, `ensure_ascii=False`, звук base64 int16 LE 16 кГц mono. Константы `dictate.py:31-35` не меняются: каденс 0.4 с, окно 18 с (S1, `poc/live2ch/RESULT.md:7,56-68`).

### Правило совместимости (D1, решение)

**Форма событий фиксируется при создании сессии.** Сессия, созданная командой **без** `ch`, — «унаследованная»: её события байт в байт как сегодня (`commit`/`preview` без `ch`, `stat` при закрытии фразы, `flush` → `reason:"manual"`). Сессия, созданная через `open` или первой командой **с** `ch`, — «канальная»: события несут `ch` и `phrase`, вместо `stat` — `phrase`. `ready` и `quit` не меняются. Это удовлетворяет и «`phrase` заменяет `stat`» (feature-prompter.md:384-385) для каналов, и «без `ch` всё как раньше» (:366-367, план :52-53); `test_dictate.py:141-166,194` остаются зелёными без правок.

### Команды (← stdin)

| Строка | Эффект |
|---|---|
| `{"t":"open","ch":"them","label":"Собеседник"}` | создать канальную сессию `them` (свои VAD, трекер, счётчики `received`, `phrase=1`). Повторный `open` того же `ch` — заменить сессию новой (счётчики с нуля), без событий. `ch` отсутствует → `{"t":"error","message":"open без ch"}`. `label` принимается, в событиях не используется. |
| любая команда с `"ch":"main"` | `{"t":"error","ch":"main","message":"канал main зарезервирован"}` — иначе `audio` с `ch:"main"` создал бы канальную сессию под ключом диктовки, и клиент диктовки получал бы события с `ch`. |
| `{"t":"audio","ch":"them","pcm":"…"}` | `feed` в сессию `them`; если не открыта — создать канальную с `label = ch` (как в спайке `poc/live2ch/run.py:63-66`). |
| `{"t":"audio","pcm":"…"}` | как сегодня: сессия `main`, унаследованная. |
| `{"t":"flush","ch":"them"}` | `flush(reason="flush")` (docs/feature-prompter.md:380). Без `ch` — `flush()` → `"manual"` (как сегодня). |
| `{"t":"reset","ch":"them"}` | сбросить окно/трекер/VAD; **`received` и `phrase` не трогать** (t0/t1 — от `open`, docs/feature-prompter.md:383). Без `ch` — как сегодня. |
| `{"t":"close","ch":"them"}` | `flush(reason="flush")` → события → удалить сессию. Неизвестный `ch` — ничего. |
| `{"t":"quit"}` | как сегодня: выход **без** flush (`dictate.py:263-264`). Клиент обязан `close` каналы сам. |
| иное / не JSON | как сегодня; `error` несёт `ch`, если он был в команде. |

### События (→ stdout), канальная сессия

Порядок ключей — как написано (json.dumps сохраняет порядок вставки).

```
{"t":"ready"}
{"t":"commit","ch":"them","phrase":12,"text":"…"}
{"t":"preview","ch":"them","phrase":12,"text":"…"}
{"t":"phrase","ch":"them","phrase":12,"t0":183.2,"t1":190.6,"text":"…","reason":"silence","window_sec":7.4,"decodes":18}
{"t":"error","ch":"them","message":"…"}
```

- `phrase` — номер текущей открытой фразы, с 1; после события `phrase` увеличивается на 1. `commit`/`preview` несут номер фразы, к которой относятся.
- `t0 = round((received − window.size)/sr, 2)`, `t1 = round(received/sr, 2)`, где `received` — все сэмплы, принятые сессией с `open` (включая тишину). Кадры по 0.1 с дают точные десятые.
- `text` в `phrase` — **финальный разбор всего окна** (сегодня локальная переменная в `flush`, `dictate.py:192`), не только хвост. `commit` при flush по-прежнему несёт только хвост `rest`. Клиент берёт для ленты `phrase.text`.
- `phrase` эмитится только при непустом окне (как `stat` сегодня, `:190`); `text` может быть `""` — клиент строку с пустым текстом не показывает, но хвост очищает.
- `reason`: `silence` | `overflow` | `flush` (flush и close).
- Унаследованная сессия: без изменений, включая `stat` и `"manual"`.

### Сторож отставания (S1: «в приложении нужен сторож отставания», RESULT.md:66-69) — **[предложено]**: в worker'е, только для канальных сессий

`DictationSession(..., clock=time.monotonic, max_lag_sec=None)`. При первом `feed` запоминается `t_first = clock()`. Перед периодическим разбором: `lag = (clock() − t_first) − received/sr`; если `max_lag_sec` задан и `lag > max_lag_sec` — периодический разбор пропускается (`_undecoded` копится, VAD и flush работают как обычно). `serve` создаёт канальные сессии с `max_lag_sec=1.0`, унаследованную — с `None` (диктовка без изменений). Инвариант, без которого сторож ложно срабатывает: **приложение шлёт в распознаватель звук, выровненный по времени звонка** (дыра после пересборки микрофона заполняется нулями и уходит и в запись, и в распознаватель — `CallTracks.align`, `CallController` в приложении). При воспроизведении файлов быстрее реального времени (тесты, live2ch) `lag < 0`, пропусков нет.

### Swift-сторона

`DictationCommand.line()` и `DictationEvent.parse` не меняются. `RecognizerEvent.parse` (`app/Sources/MLaudCore/DictationProtocol.swift`) маршрутизирует по наличию `ch`. `RecognizerProcess` (`app/Sources/MLaudApp/RecognizerProcess.swift`) отдаёт события без `ch` клиенту `.dictation`, с `ch` — клиенту `.call`.

## Сайдкар каналов: запись звонка Суфлёра

Приложение пишет звонок стерео (L = «Я», R = собеседник) и кладёт в inbox **первым**
`<call_id>.channels.json` (docs/feature-prompter.md §4.3, ADR-026):

```json
{"version":1,"call_id":"2026-09-04_15-30-05","channels":{"0":"Я","1":"Собеседник"},"brief":"…"}
```

Одна строка + `\n` (пишет Swift `ChannelsSidecar.encoded()`); worker читает через `json.loads`,
форматирование не важно. `brief` — опущен, когда нет (этап 3 — всегда); отсутствие и `null`
worker трактует одинаково. Ключи каналов — строки `"0"`, `"1"`; `call_id` — `%Y-%m-%d_%H-%M-%S`
в местном времени.

Порядок появления файлов: сайдкар (atomic tmp+rename в inbox) → `<inbox>/.incoming/<call_id>.pcm`
растёт весь звонок → по «Стоп» `.incoming/<call_id>.wav` → `afconvert` → `.incoming/<call_id>.m4a`
→ `rename` в `<inbox>/<call_id>.m4a` → удалить `.pcm`/`.wav`. `.incoming` сканер не видит
(скрытый каталог, `pipeline.list_audio`), сайдкар не аудио — очередь не трогает.

Конвейер (`pipeline.process_file`, `channels.py`): рядом с аудио есть сайдкар → диаризация
и голос-ID **не запускаются**, каждая дорожка транскрибируется отдельно (`afconvert` без `-c`,
временные mono-WAV, `transcriber.transcribe` на каждый), реплики получают `speaker` из
подписи канала и `channel` 0/1 и сливаются по времени (при равном `start` — сначала канал 0).
Сайдкар `speakers.json` для окна «Голоса» не пишется. Моно с сайдкаром, сайдкар не версии 1,
без `"0"`/`"1"`, с не-строковыми подписями или не JSON — ошибка, оба файла уходят в карантин
`Failed/`. Результат `process_file` получает ключ `"channels"` (`None` без сайдкара).

Архив: `Processed/AllRecords/<YYYY-MM>/<call_id>.m4a` + `<call_id>.channels.json` рядом.

`.meta.json` / артефакт роутеру (`artifact.py`) — только добавления:

- `started_at` — из `call_id` (местная зона), `started_at_source: "sidecar"` (новое значение
  перечисления): `afconvert` пишет в `mvhd` время конвертации, и метаданным файла верить нельзя.
- блок `"prompter": {"call_id":"…","brief":"…"|null,"goal":null,"outcome_path":"ASROutput/AllOutputs/2026-09/<base>.prompter.md"}`
  — последним ключом и только когда рядом с `.txt` лежит `<base>.prompter.md` **и** есть
  сайдкар каналов. В этапе 3 итоги не возникают — ветка спит. `goal` — `null` до этапа 4.

Ограничение: `python -m mlaud_worker.voices prepare` идёт через `pipeline.analyze()` и на
стерео-записи звонка продолжит сводить каналы в моно и диаризовать — подписи «Я»/«Собеседник»
он не восстанавливает.

## Подсказчик (`mlaud_worker.prompter`) — резидентный и одноразовые режимы

Один звонок = одна беседа с моделью: системный промт (роль → профиль → бриф → дополнение
шаблона → материалы → схема) строго первым и не меняется; каждый ход — новым user-сообщением
с репликами с прошлого хода. Дебаунс 2.5 с, копление на время полёта, лимит запросов в
минуту и потолок стоимости — внутри (FR-12.14); карточки идут стримом по мере закрытия
объектов. Файлы звонка (в `~/ASR/Prompter/calls/<id>/`, корень переопределяется
`MLAUD_PROMPTER_DIR`): `cards.jsonl`, `outcome.json`, `outcome.md`, `prompter.log.jsonl`
пишет Python; ключ — только переменной `MLAUD_LLM_KEY`, никогда аргументом и не в логах
(`logutil.redact` маскирует `Bearer …` и `sk-…`).

Транспорт как у диктовки: JSON-строки в обе стороны (`json.dumps(ensure_ascii=False)+"\n"`
+ flush), stdin читается всегда — `finish`/`quit` не ждут летящего запроса. Команды:
`start` (один раз; connection как в start, limits), `turn` (reason
`them_phrase|manual|timer`, lines — новые строки обоих каналов с прошлого хода),
`pause`, `detail` (вне истории беседы), `finish`, `quit`. События: `ready`, `warm`,
`card`/`cards`, `detail`, `waiting` (rpm), `paused` (потолок), `outcome`, `error`
(fatal — суфлёр выключен, транскрипт и запись живут). Точный порядок ключей — фикстуры
`tests/fixtures/protocol/{commands,events}.jsonl`.

После звонка: конвейер (`pipeline.process_file`) для записи с сайдкаром копирует
`outcome.md` из папки звонка в `ASROutput/AllOutputs/<мес>/<id>.prompter.md`, доставляет
в Telegram после транскрипта и пишет `goal` из брифа в блок `prompter` артефакта; итоги
опоздали — `outcome_path: null`. Повтор/опоздавшие итоги — руками:

```bash
echo '{"connection":{"base_url":"…","model":"…","reasoning":null,"price_per_mtok":{}}}' \
  | MLAUD_LLM_KEY=sk-… .venv/bin/python -m mlaud_worker.prompter --check   # {"ok":true,"ttft_ms":…}; отказ → exit 1, нет ключа → 2
.venv/bin/python -m mlaud_worker.prompter --materials <папка брифа>/materials [--budget 120000]
.venv/bin/python -m mlaud_worker.telegram send <путь>/outcome.md [--caption ТЕКСТ]
```

Зависимости: `httpx>=0.28,<1`, `pypdf>=5,<7` (в `requirements.txt`, ставятся в оба venv).

## Офлайн-режим: живая пометка «Я / не я» (этап 5)

Один микрофон (телефон, встреча в комнате): канал `me` открывается с флагом
`{"t":"open","ch":"me","label":"Я","voice":true}` — и закрытая фраза несёт
`voice: {"self": true, "score": 0.71, "speech": 3.4}`, если в её доминирующей дорожке
речи ≥ 1.5 с. Эмбеддится только речь: окно режется на дорожки говорящих моделью
`pyannote/segmentation-3.0` (powerset, CPU), метка — по дорожке с максимумом речи;
сырое окно не эмбеддится никогда — тракт MacBook-микрофона после гейта «Изоляции
голоса» состоит из нулей на 48–65 %, и отпечаток такого окна — тишина, а не голос
(poc/livespk/RESULT.md). Счёт — лучший косинус по образцам персоны «Я», порог 0.40
(замер на живых звонках: свои 0.50–0.75, чужие ≤ 0.23). Эмбеддинг — wespeaker на CPU,
обе модели грузятся лениво при первом голосовом канале; смена базы голосов
подхватывается следующим `open` без перезапуска. Пометки — только события: база
голосов живым режимом не меняется. Персоны «Я» нет — канал отвечает ошибкой с
подсказкой записать эталон. Запись встречи — моно без сайдкара каналов, конвейер
обрабатывает её штатной диаризацией.

Режим микрофона macOS читается приложением при старте захвата: не «Стандартный» —
баннер на экране звонка (гейт душит паузы и соседние голоса, пометка не работает).

Эталон — чистая запись одного человека: ≥ 30 с речи без длинных пауз
(кнопка в приложении пишет 45 с — с запасом на микропаузы), обычным разговорным
голосом и с обычного места: «начитка вплотную к микрофону» и разговорная речь
дают разные отпечатки, и эталон должен совпадать с условиями звонка:

```bash
.venv/bin/python -m mlaud_worker.voices enroll-reference ~/ASR/service/self-voice/2026-09-07_12-00-00.wav
```

Берёт самый длинный кластер диаризации и кладёт его в базу как персону «Я» (канал
`reference`); речи меньше минимума (30 с по умолчанию) — отказ.

## Тесты

```bash
.venv/bin/python -m pytest -q
```

283 теста (декодирование+регрессия ресемплинга, форматирование, Telegram-мок, конвейер,
идемпотентность, диаризация, база голосов, протокол диктовки и каналов, сайдкар каналов,
подсказчик: бриф/материалы/промты/итоги/провайдер на MockTransport/оркестратор/сквозной
прогон с подставной моделью; офлайн: живая пометка, эталонная запись, база не трогается). Тест end-to-end использует реальную запись
(путь из `MLAUD_TEST_M4A`, иначе первый `.m4a` из `../test data/`), регрессия узнавания — данные замера `~/ASR/spkid-eval`
(оба пропускаются, если данных нет); `test_channels_real_model_end_to_end` синтезирует
две фразы через `say -v Milena` и гонит их через настоящую модель. Быстрый прогон без моделей:
`.venv/bin/python -m pytest -q tests -k "not end_to_end and not real_model"`. Гонять стоит в обоих venv: `.venv` (numpy 2) и
`../poc/.venv` (стек бандла, numpy 1.26, pyannote).
