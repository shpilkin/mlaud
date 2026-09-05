# MLaud Worker (Python)

Эфемерный обработчик: декодирует аудио, транскрибирует локально (GigaAM-v3 MLX, RNNT),
пишет `.txt`/`.srt` с тайм-кодами, доставляет в Telegram файлом, архивирует аудио.
Запускается Swift-приложением как подпроцесс (см. ../docs/architecture.md).

## Модули

- `audio.py` — декодирование без ffmpeg: `afconvert` (macOS) + `soundfile` + ресемплинг `soxr` до 16 кГц.
  ⚠️ Всегда читаем фактическую частоту и ресемплим (ADR-014; иначе баг 48к→мусор).
- `transcribe.py` — обёртка над `gigaam-mlx`: модель грузится один раз, ffmpeg-free загрузчик.
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

## Тесты

```bash
.venv/bin/python -m pytest -q
```

117 тестов (декодирование+регрессия ресемплинга, форматирование, Telegram-мок, конвейер,
идемпотентность, диаризация, база голосов). Тест end-to-end использует реальную запись
`../test data/Пример записи.m4a`, регрессия узнавания — данные замера `~/ASR/spkid-eval`
(оба пропускаются, если данных нет). Гонять стоит в обоих venv: `.venv` (numpy 2) и
`../poc/.venv` (стек бандла, numpy 1.26, pyannote).
