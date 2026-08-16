"""Сдача артефакта роутеру: устойчивый id встречи, честное время записи, папка обмена.

Канонический документ фичи — в репозитории Niti (`email_reader/docs/feature-routing.md`),
сторона mlaud — `docs/feature-routing.md`. Здесь ровно то, что делает worker: считает id
по СОДЕРЖИМОМУ аудио, определяет время начала записи, кладёт описание рядом с транскриптом
и (если включено) json в папку обмена. Ни классификации, ни проектов, ни записи в чужие
папки — этим занимается роутер.
"""

import hashlib
import json
import os
import re
import struct
from datetime import UTC, datetime, timedelta
from pathlib import Path

# MP4/QuickTime отсчитывает время от 1904-01-01 UTC (ISO/IEC 14496-12).
_QT_EPOCH = datetime(1904, 1, 1, tzinfo=UTC)

# Имена файлов из реального архива: «2026-08-16_14-30-05», «31 Dec 2025 at 20:55:55».
_NAME_PATTERNS = (
    (re.compile(r"(\d{4})-(\d{2})-(\d{2})[_ T](\d{2})[-:](\d{2})[-:](\d{2})"),
     lambda m: tuple(int(x) for x in m.groups())),
)
_MONTHS = {m: i for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1
)}
_NAME_EN = re.compile(r"(\d{1,2}) ([A-Z][a-z]{2}) (\d{4}) at (\d{2}):(\d{2}):(\d{2})")

_HASH_CHUNK = 1024 * 1024


def meeting_id(path: Path) -> str:
    """Устойчивый id встречи: первые 16 hex от sha256 СОДЕРЖИМОГО аудио.

    Именно содержимого, а не имени: файл переименуют или перенесут — это та же встреча,
    и роутер не должен завести вторую."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(_HASH_CHUNK):
            h.update(chunk)
    return h.hexdigest()[:16]


def _iter_boxes(f, end: int):
    """Итератор по ISO-BMFF боксам на текущем уровне: (тип, смещение, размер)."""
    while f.tell() < end:
        start = f.tell()
        header = f.read(8)
        if len(header) < 8:
            return
        size, kind = struct.unpack(">I4s", header)
        if size == 1:                      # 64-битный размер лежит следом
            raw = f.read(8)
            if len(raw) < 8:
                return
            size = struct.unpack(">Q", raw)[0]
        elif size == 0:                    # бокс до конца файла
            size = end - start
        if size < 8:
            return                         # битая структура — дальше не идём
        yield kind.decode("latin1", "ignore"), start, size
        f.seek(start + size)


def read_mp4_meta(path: Path) -> dict:
    """Время создания и длительность из бокса mvhd. {} если это не mp4/m4a или бокса нет.

    Поле creation_time хранится в UTC. Проверено на записях из архива: у файла
    «31 Dec 2025 at 20:55:55.m4a» mvhd даёт 17:55:55 UTC — ровно то же местное время,
    что и в имени (MSK = UTC+3)."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            for kind, start, box_size in _iter_boxes(f, size):
                if kind != "moov":
                    continue
                f.seek(start + 8)
                for inner, inner_start, _ in _iter_boxes(f, start + box_size):
                    if inner != "mvhd":
                        continue
                    f.seek(inner_start + 8)
                    version = f.read(4)[0]
                    if version == 1:
                        created, _mod, timescale, duration = struct.unpack(">QQIQ", f.read(28))
                    else:
                        created, _mod, timescale, duration = struct.unpack(">IIII", f.read(16))
                    out: dict = {}
                    if created:
                        out["created_at"] = _QT_EPOCH + timedelta(seconds=created)
                    if timescale and duration:
                        out["duration_sec"] = int(round(duration / timescale))
                    return out
    except (OSError, struct.error, IndexError):
        return {}
    return {}


def _from_name(name: str) -> datetime | None:
    """Метка времени, ЯВНО записанная в имени файла (местное время). None, если её нет."""
    for pattern, extract in _NAME_PATTERNS:
        m = pattern.search(name)
        if m:
            y, mo, d, hh, mm, ss = extract(m)
            return datetime(y, mo, d, hh, mm, ss).astimezone()
    m = _NAME_EN.search(name)
    if m and m.group(2) in _MONTHS:
        d, mon, y, hh, mm, ss = m.groups()
        return datetime(
            int(y), _MONTHS[mon], int(d), int(hh), int(mm), int(ss)
        ).astimezone()
    return None


def started_at(path: Path, duration_sec: int | None = None) -> tuple[datetime, str]:
    """Начало записи и то, откуда оно взято (источник пишем в сайдкар — иначе непонятно,
    чему верить).

    Порядок: метаданные аудио → метка времени в имени → mtime минус длительность → mtime.

    Порядок отличается от `docs/feature-routing.md`, где имя файла стояло последним, а
    `mtime − duration` — вторым. Основание — сами файлы архива: у «New Recording 13.m4a»
    mtime всего на 5 секунд позже creation_time при длительности 32 минуты, то есть mtime
    здесь — момент финализации файла (≈ начало), а не конец записи. Вычитать из него
    длительность значит уехать на полчаса назад. Имя, В КОТОРОМ есть полная метка времени,
    — точное свидетельство; имена без метки («New Recording 20») просто не совпадут
    с шаблоном и пойдут дальше по цепочке."""
    meta = read_mp4_meta(path)
    created = meta.get("created_at")
    if created is not None:
        return created, "audio-metadata"

    from_name = _from_name(path.name)
    if from_name is not None:
        return from_name, "filename"

    mtime = datetime.fromtimestamp(path.stat().st_mtime, UTC)
    duration = duration_sec or meta.get("duration_sec")
    if duration:
        return mtime - timedelta(seconds=duration), "mtime-duration"
    return mtime, "mtime"


def _relative(path: Path, root: Path | None) -> str:
    """Путь от корня архива. Абсолютный — только если файл лежит вне корня: перенос
    архива не должен рвать ссылку (§9.2)."""
    if root is not None:
        try:
            return str(Path(path).resolve().relative_to(Path(root).resolve()))
        except ValueError:
            pass
    return str(path)


def build_payload(
    *,
    audio_path: Path,
    txt_path: Path,
    srt_path: Path | None,
    asr_root: Path | None,
    duration_sec: int | None = None,
) -> dict:
    """Описание встречи для роутера. Только то, что известно ДО маршрутизации: ни проектов,
    ни уверенности — их определит Niti."""
    meta = read_mp4_meta(audio_path)
    # Длительность самого файла точнее, чем конец последнего сегмента: расшифровка
    # обрывается на последней реплике, а запись обычно идёт ещё какое-то время.
    duration = meta.get("duration_sec") or duration_sec
    when, source = started_at(audio_path, duration)
    payload = {
        "meeting_id": meeting_id(audio_path),
        "started_at": when.astimezone().isoformat(),
        "started_at_source": source,
        "duration_sec": duration,
        "asr_root": str(asr_root) if asr_root else None,
        "transcript_path": _relative(txt_path, asr_root),
        "audio_path": _relative(audio_path, asr_root),
        "source": "mlaud",
    }
    if srt_path is not None:
        payload["srt_path"] = _relative(srt_path, asr_root)
    return payload


def _write_atomic(path: Path, text: str) -> None:
    """Во временный файл рядом, затем rename: читатель никогда не увидит половину."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def write_sidecar(txt_path: Path, payload: dict) -> Path:
    """`<base>.meta.json` рядом с транскриптом. Один файл — один писатель: Niti в архив
    записей не пишет вообще."""
    path = Path(txt_path).with_suffix(".meta.json")
    _write_atomic(path, json.dumps(payload, ensure_ascii=False, indent=2))
    return path


def handoff(inbox: Path | None, payload: dict) -> Path | None:
    """Положить json в папку обмена роутера. None, если обмен выключен.

    Удаляет файл Niti — после того как поставит событие в очередь. Роутер не запущен →
    json ждёт; та же развязка, что iCloud-inbox даёт для аудио."""
    if inbox is None:
        return None
    path = Path(inbox) / f"{payload['meeting_id']}.json"
    _write_atomic(path, json.dumps(payload, ensure_ascii=False, indent=2))
    return path
