"""Оркестрация пакетной обработки: inbox → транскрипция → вывод → доставка → архив.

Состояние выражено расположением файлов: файл в inbox = ждёт; перемещён в processed = готов.
"""

import os
import re
import shutil
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

from . import channels, delivery_queue
from .config import Config
from .logutil import redact
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
        msg = redact(str(e))  # requests кладёт в текст URL с токеном бота — маскируем
        try:
            notifier.send_error(f"{base}: доставка не удалась — {msg}")
        except Exception:
            pass
        return f"failed: {msg}"


@dataclass
class Analysis:
    """Разобранная запись: реплики и, при диаризации, кластеры с их подписями."""
    segments: list
    turns: list = field(default_factory=list)
    centroids: dict = field(default_factory=dict)
    names: dict = field(default_factory=dict)
    idents: dict = field(default_factory=dict)


def analyze(path: Path, cfg: Config, transcriber: Transcriber,
            diarizer=None, gallery=None) -> Analysis:
    """Транскрипция (→ диаризация → имена) без записи на диск.

    Общее ядро конвейера и «разметить старую запись» (voices.py prepare): второй путь
    делает то же самое, только без доставки и архивации.
    `gallery` — {имя: центроид} из базы голосов; None/пусто — «Спикер N» везде.
    """
    if diarizer is None:
        return Analysis(segments=transcriber.transcribe(str(path)))
    # Точная диаризация: слова с тайм-кодами → разметка по спикерам → склейка в реплики.
    # Имена подставляются на уровне подписей кластеров, вывод про них не знает.
    from .diarize import group_words_by_speaker, identify_speakers, name_speakers
    num = cfg.num_speakers or None
    turns, centroids = diarizer.diarize(str(path), num_speakers=num)
    words = transcriber.transcribe_words(str(path))
    idents = identify_speakers(turns, centroids, gallery or {},
                               cfg.identify_threshold, cfg.identify_min_speech)
    names = name_speakers(turns, centroids, gallery or {},
                          cfg.identify_threshold, cfg.identify_min_speech, idents=idents)
    segments = group_words_by_speaker(words, turns, mapping=names)
    return Analysis(segments, turns, centroids, names, idents)


def process_file(path: Path, cfg: Config, transcriber: Transcriber,
                 notifier=None, diarizer=None, gallery=None) -> dict:
    """Обработать один файл: транскрипция (→ диаризация → имена) → запись → доставка → архив.

    Запись звонка Суфлёра (рядом лежит `<call_id>.channels.json`) транскрибируется по
    дорожкам без диаризации: кто говорит — известно по каналу (docs/feature-prompter.md §4.3).
    Битый сайдкар — исключение, оба файла уходят в карантин."""
    sidecar_file = channels.find_sidecar(path)
    if sidecar_file is not None:
        sidecar = channels.read_sidecar(sidecar_file)
        result = Analysis(segments=channels.transcribe_channels(path, sidecar, transcriber))
    else:
        sidecar = None
        result = analyze(path, cfg, transcriber, diarizer, gallery)
    segments = result.segments
    period = derive_period(path)
    base = path.stem

    out_dir = cfg.output / period
    outputs = write_outputs(segments, out_dir, base)

    # Итоги суфлёра (§3.7): копия outcome.md рядом с транскриптом — до доставок, чтобы
    # блок prompter в артефакте нашёл файл. Итоги опоздали/отменены — копии нет.
    prompter_md = None
    if sidecar is not None:
        from . import prompter_files
        outcome = prompter_files.outcome_md(cfg, sidecar.call_id)
        if outcome is not None:
            prompter_md = prompter_files.copy_outcome(outcome, out_dir, base)

    # Сайдкар для разметки голосов — до архивации: клипы режутся из исходного аудио.
    # Пишется и при пустой базе: иначе первый голос завести неоткуда.
    speakers = None
    if sidecar is None and diarizer is not None and cfg.identify:
        speakers = _write_speakers(cfg, path, period, base, outputs, result.turns,
                                   result.centroids, result.names, result.idents, segments)

    delivery = _deliver(notifier, outputs["txt"], base)
    # Сбой доставки (сеть/Telegram недоступны) — в очередь на автоповтор следующим прогоном.
    if delivery.startswith("failed"):
        delivery_queue.enqueue(cfg, outputs["txt"], base)

    # Итоги — после транскрипта (FP:642-644): «расшифровка → итоги».
    outcome_delivery = _deliver_outcome(notifier, cfg, prompter_md, base)

    # Архив ВСЕГДА (даже при сбое доставки) — переносим аудио из inbox на локальный диск.
    proc_dir = cfg.processed / period
    proc_dir.mkdir(parents=True, exist_ok=True)
    dest = proc_dir / path.name
    shutil.move(str(path), str(dest))
    if sidecar_file is not None:
        shutil.move(str(sidecar_file), str(proc_dir / sidecar_file.name))

    # Сдача артефакта роутеру — после архивации, чтобы в описании стоял путь к аудио на
    # его постоянном месте. Никогда не роняет обработку: роутер может быть не запущен,
    # папка обмена — недоступна, а транскрипт уже сделан и доставлен.
    from . import prompter_files
    artifact = _handoff(dest, outputs, segments, cfg,
                        started_at=channels.started_at(sidecar) if sidecar else None,
                        sidecar=sidecar,
                        goal=prompter_files.goal(cfg, sidecar.call_id) if sidecar else None)

    return {
        "source": path.name,
        "period": period,
        "segments": len(segments),
        "txt": outputs["txt"],
        "srt": outputs["srt"],
        "archived": dest,
        "delivery": delivery,
        "outcome_delivery": outcome_delivery,
        "artifact": artifact,
        "speakers": speakers,
        "channels": sidecar.channels if sidecar else None,
    }


def _deliver_outcome(notifier, cfg, prompter_md: Path | None, base: str) -> str:
    """Доставка итогов суфлёра после транскрипта. НИКОГДА не бросает (как _deliver);
    нет итогов — "none"; сбой — в очередь автоповтора тем же файлом."""
    if prompter_md is None:
        return "none"
    if notifier is None:
        return "skipped"
    try:
        notifier.send_document(prompter_md, caption=f"{base} — итоги")
        return "sent"
    except Exception as e:  # noqa: BLE001
        msg = redact(str(e))
        delivery_queue.enqueue(cfg, prompter_md, base + ".prompter")
        try:
            notifier.send_error(f"{base} — итоги: доставка не удалась — {msg}")
        except Exception:
            pass
        return f"failed: {msg}"


def _write_speakers(cfg, path, period, base, outputs, turns, centroids, names, idents,
                    segments) -> dict:
    """Сайдкар записи (speakers.py). Никогда не роняет обработку: транскрипт уже готов."""
    from . import speakers as spk

    try:
        sidecar = spk.write(cfg, path, period=period, base=base, outputs=outputs,
                            turns=turns, centroids=centroids, names=names, idents=idents,
                            segments=segments)
        return {"status": "written", "pending": spk.pending_count(sidecar),
                "path": str(spk.sidecar_dir(cfg, period, base) / spk.FILE_NAME)}
    except Exception as e:  # noqa: BLE001
        return {"status": f"failed: {redact(str(e))}", "pending": 0}


def _segments_duration(segments: list[dict]) -> Optional[int]:
    """Длительность по последнему сегменту — запасной вариант, когда в файле нет mvhd."""
    ends = [s.get("end") or 0 for s in segments]
    return int(round(max(ends))) if ends and max(ends) > 0 else None


def _handoff(audio_path: Path, outputs: dict, segments: list[dict], cfg: Config, *,
             started_at: Optional[datetime] = None, sidecar=None,
             goal: Optional[str] = None) -> str:
    """Сайдкар рядом с транскриптом + json в папку обмена. Возвращает статус для лога.

    `started_at`/`sidecar`/`goal` — для записи звонка: время из call_id, блок Суфлёра,
    когда рядом с транскриптом лежат итоги `<base>.prompter.md` (копию сделал process_file),
    и цель из brief.md по call.json."""
    from . import artifact

    try:
        prompter = None
        if sidecar is not None:
            prompter_md = outputs["txt"].with_name(audio_path.stem + ".prompter.md")
            prompter = artifact.prompter_block(
                call_id=sidecar.call_id, brief=sidecar.brief, goal=goal,
                outcome_path=prompter_md if prompter_md.exists() else None,
                asr_root=cfg.asr_root,
            )
        payload = artifact.build_payload(
            audio_path=audio_path,
            txt_path=outputs["txt"],
            srt_path=outputs.get("srt"),
            asr_root=cfg.asr_root,
            duration_sec=_segments_duration(segments),
            started_at=started_at,
            prompter=prompter,
        )
        artifact.write_sidecar(outputs["txt"], payload)
        if cfg.router_inbox is None:
            return "sidecar"
        if not cfg.router_inbox.parent.exists():
            # Роутер не установлен: его каталог данных отсутствует. Создавать папку
            # обмена внутри несуществующего каталога незачем — jsonы копились бы там,
            # где их никто не читает.
            return "no-router"
        artifact.handoff(cfg.router_inbox, payload)
        return "sent"
    except Exception as e:  # noqa: BLE001 — сдача артефакта не должна ломать конвейер
        return f"failed: {redact(str(e))}"


def _load_gallery(cfg: Config) -> dict:
    """База голосов для матчинга. Нет каталога — пустая база, «Спикер N» везде."""
    from .voices import VoiceStore
    return VoiceStore(cfg.voices_dir).gallery()


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
    results = {"processed": [], "errors": [], "redelivered": [], "pending": [],
               "given_up": [], "identify_error": None}

    def _run():
        nonlocal transcriber, diarizer
        gallery = None
        # Сначала досылаем всё, что не ушло в прошлые разы (сеть могла вернуться).
        # Дёшево: модель НЕ грузим, если транскрибировать нечего — прогон может быть
        # чисто «досыльным» (inbox пуст, но в очереди висит недоставленное).
        flushed = delivery_queue.flush(cfg, notifier, _deliver)
        results["redelivered"] = flushed["resent"]
        results["given_up"] = flushed.get("given_up", [])
        files = list_audio(cfg)
        if files:
            transcriber = transcriber or Transcriber(model_type=cfg.model_type)
            if diarizer is None:
                diarizer = _build_diarizer(cfg)
            # Идентификация — только поверх диаризации; база читается раз на прогон.
            # Битая база не должна останавливать транскрипцию: имена — опция,
            # файлы копились бы в inbox из-за одного испорченного json.
            if diarizer is not None and cfg.identify:
                try:
                    gallery = _load_gallery(cfg)
                except Exception as e:  # noqa: BLE001
                    results["identify_error"] = redact(str(e))
                # Старые сайдкары с клипами и векторами — биометрия, чистим по возрасту.
                try:
                    from . import speakers as spk
                    spk.sweep(cfg)
                except Exception:  # noqa: BLE001
                    pass
        for path in files:
            try:
                results["processed"].append(
                    process_file(path, cfg, transcriber, notifier, diarizer, gallery)
                )
            except Exception as e:  # noqa: BLE001 — один файл не должен ронять пакет
                results["errors"].append({"source": path.name, "error": redact(str(e))})
                # Карантин: переносим упавший файл из inbox, иначе он переобрабатывается
                # каждый проход и бесконечно спамит ошибками (NFR: без вечных ретраев).
                try:
                    cfg.failed.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(path), str(cfg.failed / path.name))
                except Exception:
                    pass
                sidecar_file = channels.find_sidecar(path)
                if sidecar_file is not None:
                    try:
                        shutil.move(str(sidecar_file), str(cfg.failed / sidecar_file.name))
                    except Exception:
                        pass
                if notifier is not None:
                    try:
                        notifier.send_error(f"{path.name}: {redact(str(e))}")
                    except Exception:
                        pass

    if use_lock:
        with file_lock(cfg):
            _run()
    else:
        _run()
    # Итоговое состояние очереди (после досыла и после новых сбоев за этот прогон).
    results["pending"] = delivery_queue.pending_bases(cfg)
    return results
