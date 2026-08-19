"""Очередь недоставленных транскриптов.

Проблема: если в момент обработки сеть/Telegram недоступны, транскрипт готов и лежит
локально, но в чат не улетает — и раньше повторной попытки не было (оседал молча).

Решение: при сбое доставки запоминаем txt-файл в очереди (JSON в service-каталоге).
На следующем прогоне worker сначала пытается дослать всё из очереди; что доставлено —
выбрасывается, что снова упало — остаётся ждать. Так пропущенные разговоры прилетают
сами, как только сеть вернётся, без ручной переотправки.

Попыток на транскрипт — не больше MAX_ATTEMPTS, считая первичную отправку. Дальше
запись выбрасывается из очереди со строкой GIVEUP в логе: транскрипт лежит на диске,
а бесконечно долбиться в лежащую сеть незачем. Плата за это честная: если сеть лежит
дольше, чем длятся оставшиеся попытки, этот транскрипт сам в Telegram не прилетит.

Очередь читается/пишется только под общим файловым локом process_inbox — гонок нет.
"""

import json
from datetime import datetime
from pathlib import Path

QUEUE_NAME = "pending_delivery.json"
MAX_ATTEMPTS = 3  # всего отправок на транскрипт, включая первичную (из process_file)


def _queue_path(cfg) -> Path:
    return cfg.service / QUEUE_NAME


def _load(cfg) -> list:
    p = _queue_path(cfg)
    if not p.exists():
        return []
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []
    return data if isinstance(data, list) else []


def _save(cfg, entries: list) -> None:
    p = _queue_path(cfg)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(p)  # атомарная замена


def enqueue(cfg, txt_path, base: str) -> None:
    """Поставить недоставленный транскрипт в очередь (без дублей по пути txt)."""
    txt = str(txt_path)
    entries = _load(cfg)
    if any(e.get("txt") == txt for e in entries):
        return
    entries.append({
        "txt": txt,
        "base": base,
        "failed_at": datetime.now().isoformat(timespec="seconds"),
        "attempts": 1,  # первичная отправка уже провалилась — она первая из MAX_ATTEMPTS
    })
    _save(cfg, entries)


def count(cfg) -> int:
    return len(_load(cfg))


def pending_bases(cfg) -> list:
    """Имена (base) всё ещё недоставленных транскриптов из очереди."""
    return [e.get("base") or Path(e.get("txt", "")).stem for e in _load(cfg)]


def flush(cfg, notifier, deliver) -> dict:
    """Попытаться дослать всё из очереди.

    deliver — функция (notifier, Path, base) -> str-статус ('sent'/'empty'/'failed…').
    Успешно доставленные (и исчезнувшие файлы) убираются из очереди; упавшие остаются
    до MAX_ATTEMPTS попыток, после чего выбрасываются в 'given_up'.
    Возвращает {'resent': [base…], 'still_pending': [base…], 'given_up': [{base, txt}…]}.
    """
    entries = _load(cfg)
    if not entries:
        return {"resent": [], "still_pending": [], "given_up": []}
    if notifier is None:
        # Без notifier'а отправки не было — попытку не засчитываем.
        return {"resent": [], "given_up": [],
                "still_pending": [e.get("base", "?") for e in entries]}

    kept, resent, given_up = [], [], []
    for e in entries:
        txt = Path(e.get("txt", ""))
        base = e.get("base") or txt.stem
        if not txt.exists():
            continue  # исходный txt удалён — просто выбрасываем из очереди
        status = deliver(notifier, txt, base)
        if status in ("sent", "empty"):
            resent.append(base)
            continue
        # Записи, созданные до появления счётчика: одна попытка (первичная) уже была.
        attempts = int(e.get("attempts", 1)) + 1
        if attempts >= MAX_ATTEMPTS:
            given_up.append({"base": base, "txt": str(txt)})
            continue
        e["attempts"] = attempts
        kept.append(e)
    _save(cfg, kept)
    return {
        "resent": resent,
        "still_pending": [e.get("base", "?") for e in kept],
        "given_up": given_up,
    }
