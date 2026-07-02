"""Очередь недоставленных транскриптов.

Проблема: если в момент обработки сеть/Telegram недоступны, транскрипт готов и лежит
локально, но в чат не улетает — и раньше повторной попытки не было (оседал молча).

Решение: при сбое доставки запоминаем txt-файл в очереди (JSON в service-каталоге).
На следующем прогоне worker сначала пытается дослать всё из очереди; что доставлено —
выбрасывается, что снова упало — остаётся ждать. Так пропущенные разговоры прилетают
сами, как только сеть вернётся, без ручной переотправки.

Очередь читается/пишется только под общим файловым локом process_inbox — гонок нет.
"""

import json
from datetime import datetime
from pathlib import Path

QUEUE_NAME = "pending_delivery.json"


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
    Успешно доставленные (и исчезнувшие файлы) убираются из очереди; упавшие остаются.
    Возвращает {'resent': [base…], 'still_pending': [base…]}.
    """
    entries = _load(cfg)
    if not entries:
        return {"resent": [], "still_pending": []}
    if notifier is None:
        return {"resent": [], "still_pending": [e.get("base", "?") for e in entries]}

    kept, resent = [], []
    for e in entries:
        txt = Path(e.get("txt", ""))
        base = e.get("base") or txt.stem
        if not txt.exists():
            continue  # исходный txt удалён — просто выбрасываем из очереди
        status = deliver(notifier, txt, base)
        if status in ("sent", "empty"):
            resent.append(base)
        else:
            kept.append(e)
    _save(cfg, kept)
    return {"resent": resent, "still_pending": [e.get("base", "?") for e in kept]}
