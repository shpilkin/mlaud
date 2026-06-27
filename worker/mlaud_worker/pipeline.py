"""Оркестрация пакетной обработки: inbox → транскрипция → вывод → доставка → архив.

Состояние выражено расположением файлов: файл в inbox = ждёт; перемещён в processed = готов.
"""

import os
import re
import shutil
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional

from .config import Config
from .output import write_outputs
from .transcribe import Transcriber

_MONTH_PREFIX = re.compile(r"^(\d{4}-\d{2})-\d{2}")  # YYYY-MM из префикса YYYY-MM-DD


class LockError(RuntimeError):
    pass


@contextmanager
def file_lock(cfg: Config):
    """Простой межпроцессный лок через O_CREAT|O_EXCL (NFR-4)."""
    cfg.service.mkdir(parents=True, exist_ok=True)
    lock = cfg.lock_path
    try:
        fd = os.open(str(lock), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as e:
        raise LockError(f"worker already running (lock: {lock})") from e
    try:
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
        yield
    finally:
        if lock.exists():
            lock.unlink()


def is_ready(path: Path) -> bool:
    """Файл готов к обработке: не скрытый, не iCloud-плейсхолдер, существует, не пустой,
    и физически скачан локально.

    Ловушка iCloud «Оптимизация хранилища»: выгруженный файл показывает настоящий
    st_size, но 0 выделенных блоков (данных на диске нет). Читать его нельзя —
    soundfile упадёт. Порог 4 КБ отсекает крошечные/инлайновые файлы (аудио всегда крупнее).
    """
    name = path.name
    if name.startswith("."):
        return False
    if name.endswith(".icloud"):  # недокачанный iCloud-плейсхолдер
        return False
    if not path.is_file():
        return False
    try:
        st = path.stat()
    except OSError:
        return False
    if st.st_size <= 0:
        return False
    if st.st_size > 4096 and getattr(st, "st_blocks", 1) == 0:
        return False  # выгруженный iCloud-файл: данных локально нет, ждём докачки
    return True


def list_audio(cfg: Config) -> list[Path]:
    """Готовые к обработке аудиофайлы в inbox, отсортированные по имени."""
    if not cfg.inbox.exists():
        return []
    exts = {e.lower() for e in cfg.audio_exts}
    files = [
        p for p in cfg.inbox.iterdir()
        if p.suffix.lower() in exts and is_ready(p)
    ]
    return sorted(files, key=lambda p: p.name)


def derive_period(path: Path) -> str:
    """Месячная папка YYYY-MM: из префикса имени файла, иначе из mtime."""
    m = _MONTH_PREFIX.match(path.name)
    if m:
        return m.group(1)
    ts = path.stat().st_mtime
    return datetime.fromtimestamp(ts).strftime("%Y-%m")


def _deliver(notifier, txt_path: Path, base: str) -> str:
    """Доставить результат. НИКОГДА не бросает. Возвращает статус.

    Пустой транскрипт (0 байт) Telegram отклоняет как документ (400) — поэтому
    шлём короткое сообщение вместо файла. Сбой доставки не должен мешать архивации,
    иначе файл переобрабатывается вечно и спамит ошибками.
    """
    if notifier is None:
        return "skipped"
    try:
        if txt_path.exists() and txt_path.stat().st_size > 0:
            notifier.send_document(txt_path, caption=base)
            return "sent"
        notifier.send_message(f"{base}: речь не распознана (пустой транскрипт)")
        return "empty"
    except Exception as e:  # noqa: BLE001
        try:
            notifier.send_error(f"{base}: доставка не удалась — {e}")
        except Exception:
            pass
        return f"failed: {e}"


def process_file(path: Path, cfg: Config, transcriber: Transcriber,
                 notifier=None, diarizer=None) -> dict:
    """Обработать один файл: транскрипция (→ диаризация) → запись → доставка → архив."""
    if diarizer is not None:
        # Точная диаризация: слова с тайм-кодами → разметка по спикерам → склейка в реплики.
        from .diarize import group_words_by_speaker
        num = cfg.num_speakers or None
        turns = diarizer.diarize(str(path), num_speakers=num)
        words = transcriber.transcribe_words(str(path))
        segments = group_words_by_speaker(words, turns)
    else:
        segments = transcriber.transcribe(str(path))
    period = derive_period(path)
    base = path.stem

    out_dir = cfg.output / period
    outputs = write_outputs(segments, out_dir, base)

    delivery = _deliver(notifier, outputs["txt"], base)

    # Архив ВСЕГДА (даже при сбое доставки) — переносим аудио из inbox на локальный диск.
    proc_dir = cfg.processed / period
    proc_dir.mkdir(parents=True, exist_ok=True)
    dest = proc_dir / path.name
    shutil.move(str(path), str(dest))

    return {
        "source": path.name,
        "period": period,
        "segments": len(segments),
        "txt": outputs["txt"],
        "srt": outputs["srt"],
        "archived": dest,
        "delivery": delivery,
    }


def _build_diarizer(cfg: Config):
    """Создать Diarizer, если диаризация включена и есть HF-токен; иначе None."""
    if not cfg.diarize:
        return None
    if not cfg.hf_token:
        raise RuntimeError("диаризация включена, но MLAUD_HF_TOKEN не задан")
    from .diarize import Diarizer
    return Diarizer(hf_token=cfg.hf_token, device=cfg.diarize_device or "cpu")


def process_inbox(cfg: Config, transcriber: Optional[Transcriber] = None,
                  notifier=None, use_lock: bool = True, diarizer=None) -> dict:
    """Обработать весь inbox пакетом. Возвращает {'processed': [...], 'errors': [...]}."""
    cfg.ensure_dirs()
    transcriber = transcriber or Transcriber(model_type=cfg.model_type)
    if diarizer is None:
        diarizer = _build_diarizer(cfg)
    results = {"processed": [], "errors": []}

    def _run():
        for path in list_audio(cfg):
            try:
                results["processed"].append(
                    process_file(path, cfg, transcriber, notifier, diarizer)
                )
            except Exception as e:  # noqa: BLE001 — один файл не должен ронять пакет
                results["errors"].append({"source": path.name, "error": str(e)})
                # Карантин: переносим упавший файл из inbox, иначе он переобрабатывается
                # каждый проход и бесконечно спамит ошибками (NFR: без вечных ретраев).
                try:
                    cfg.failed.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(path), str(cfg.failed / path.name))
                except Exception:
                    pass
                if notifier is not None:
                    try:
                        notifier.send_error(f"{path.name}: {e}")
                    except Exception:
                        pass

    if use_lock:
        with file_lock(cfg):
            _run()
    else:
        _run()
    return results
