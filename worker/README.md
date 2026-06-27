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
- `pipeline.py` — оркестрация inbox → транскрипция → вывод → доставка → архив; lock, идемпотентность.
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
(`rnnt`/`ctc`), `MLAUD_TG_TOKEN`, `MLAUD_TG_CHAT_ID`.

## Тесты

```bash
.venv/bin/python -m pytest -q
```

16 тестов (декодирование+регрессия ресемплинга, форматирование, Telegram-мок, конвейер,
идемпотентность). Тест end-to-end использует реальную запись `../test data/Пример записи.m4a`
(пропускается, если файла нет).
