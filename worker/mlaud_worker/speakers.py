"""Сайдкар записи для разметки голосов: кластеры, клипы, переподпись транскрипта.

Пишется при обработке, когда включена идентификация, в
`~/ASR/service/speakers/<YYYY-MM>/<base>/` (схема — docs/feature-speaker-id.md §6.2).
Окно «Голоса» в приложении его только читает; все изменения идут через
`python -m mlaud_worker.voices`, чтобы у файла был один писатель.
"""

import json
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import numpy as np
import soundfile as sf

from .audio import TARGET_SR, load_audio
from .diarize import relabel, speech_seconds
from .spkid import normalize

VERSION = 1
FILE_NAME = "speakers.json"
CLIPS_DIR = "clips"
CLIPS_PER_SPK = 3
CLIP_SEC = 6.0
MIN_TURN_SEC = 3.0          # для образца; если таких реплик мало, планка опускается до 1.5
QUOTE_MAX = 140
DEFAULT_MAX_AGE = 30 * 24 * 60 * 60   # клипы и векторы — биометрия, вечно лежать им незачем

_TXT_LINE = re.compile(r"^(\[\d\d:\d\d:\d\d\] )(.*)$")


def root(cfg) -> Path:
    return Path(cfg.service) / "speakers"


def sidecar_dir(cfg, period: str, base: str) -> Path:
    return root(cfg) / period / base


def resolve_path(arg) -> Path:
    """Путь к speakers.json из аргумента: сам файл или каталог записи."""
    p = Path(arg)
    return p / FILE_NAME if p.is_dir() else p


def load(path: Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def save(path: Path, sidecar: dict) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(sidecar, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


# --- смысл полей: одинаково для worker'а и приложения (§6.2) ---


def effective_match(cluster: dict) -> Optional[dict]:
    """Узнавание, от которого не отказались кнопкой «Нет»."""
    m = cluster.get("match")
    if not m or not m.get("name") or m["name"] in cluster.get("rejected", []):
        return None
    return m


MIXED_SUFFIX = " (смесь голосов)"


def current_name(cluster: dict) -> str:
    """Что должно стоять в транскрипте сейчас."""
    if cluster.get("assigned"):
        return cluster["assigned"]
    if cluster.get("mixed"):
        # Читателю важно знать, что в «Спикере 4» несколько человек: иначе пометка
        # живёт только в окне и ничего не меняет.
        return cluster["display"] + MIXED_SUFFIX
    if cluster.get("dismissed"):
        return cluster["display"]
    m = effective_match(cluster)
    if m:
        return m["name"] if m.get("sure") else f"{m['name']}(?)"
    return cluster["display"]


def needs_attention(cluster: dict, min_speech: float) -> bool:
    """Длинный кластер без имени: не узнан или узнан неуверенно и не подтверждён."""
    if cluster.get("speech_sec", 0.0) < min_speech or not cluster.get("embedding"):
        return False
    if cluster.get("assigned") or cluster.get("dismissed") or cluster.get("mixed") \
            or cluster.get("hidden"):
        return False
    m = effective_match(cluster)
    return not (m and m.get("sure"))


def pending_count(sidecar: dict) -> int:
    return sum(1 for c in sidecar["clusters"] if needs_attention(c, sidecar["min_speech"]))


# --- сборка ---


def pick_clip_windows(turns: list[dict]) -> list[tuple[float, float]]:
    """Три окна, разнесённые по таймлайну кластера, а не три самые длинные реплики.

    Разнесение принципиально: если pyannote слил двух людей в один кластер, образцы
    из разных мест это покажут, а «три самые длинные» — скорее спрячут.
    """
    eligible: list[dict] = []
    for floor in (MIN_TURN_SEC, 1.5, 0.0):
        eligible = [t for t in turns if t["end"] - t["start"] > floor]
        if len(eligible) >= CLIPS_PER_SPK or floor == 0.0:
            break
    if not eligible:
        return []
    eligible.sort(key=lambda t: t["start"])
    idx = sorted({int(round(f * (len(eligible) - 1))) for f in (0.15, 0.5, 0.85)})
    windows = []
    for i in idx[:CLIPS_PER_SPK]:
        t = eligible[i]
        dur = min(CLIP_SEC, t["end"] - t["start"])
        if dur < 0.5:
            continue
        mid = (t["start"] + t["end"]) / 2
        start = max(0.0, mid - dur / 2)
        windows.append((start, start + dur))
    return windows


def _quotes(segments: list[dict], names: dict) -> dict:
    """Самая длинная реплика каждого кластера — по подписи, которой он записан."""
    inverse = {display: raw for raw, display in names.items()}
    best: dict = {}
    for seg in segments:
        raw = inverse.get(seg.get("speaker"))
        if raw is None:
            continue
        text = " ".join(seg["text"].split())
        if len(text) > len(best.get(raw, "")):
            best[raw] = text
    return {raw: (q if len(q) <= QUOTE_MAX else q[:QUOTE_MAX - 1].rstrip() + "…")
            for raw, q in best.items()}


def build_clusters(turns: list[dict], centroids: dict, names: dict, idents: dict,
                   segments: list[dict], min_speech: float) -> list[dict]:
    mapping = relabel(turns)
    speech = speech_seconds(turns)
    quotes = _quotes(segments, names)
    by_label: dict = {}
    for t in turns:
        by_label.setdefault(t["speaker"], []).append(t)
    clusters = []
    for raw, display in mapping.items():
        emb = centroids.get(raw)
        embedding = None
        if emb is not None and normalize(emb) is not None:
            embedding = [round(float(x), 6) for x in np.asarray(emb).reshape(-1)]
        ident = idents.get(raw)
        match = None
        if ident is not None and ident.name is not None:
            match = {"name": ident.name, "score": round(float(ident.score), 4),
                     "sure": bool(ident.sure)}
        own = by_label.get(raw, [])
        clusters.append({
            "label": raw,
            "display": display,
            "speech_sec": round(speech.get(raw, 0.0), 1),
            "first_at": round(min(t["start"] for t in own), 2) if own else 0.0,
            "n_turns": len(own),
            "quote": quotes.get(raw, ""),
            "clips": [],
            "clip_starts": [],
            "embedding": embedding,
            "match": match,
            "written": names.get(raw, display),
            "assigned": None,
            "dismissed": False,
            "mixed": False,          # в кластере слышно нескольких: в базу нельзя (§1, вывод 2)
            "hidden": False,         # убран из списка корзиной; клипы остаются до ретенции
            "rejected": [],
        })
    return clusters


def _cut_clips(audio_path: Path, out_dir: Path, clusters: list[dict],
               turns: list[dict]) -> None:
    """Образцы режем всем кластерам: короткий имени не получит (FR-8.9), но послушать,
    кто это был, всё равно полезно."""
    windows = {c["label"]: pick_clip_windows([t for t in turns if t["speaker"] == c["label"]])
               for c in clusters}
    if not any(windows.values()):
        return
    wav = load_audio(str(audio_path))
    out_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    for c in clusters:
        for k, (a, b) in enumerate(windows[c["label"]]):
            name = f"{c['label']}_{k}.wav"
            sf.write(out_dir / name, wav[int(a * TARGET_SR):int(b * TARGET_SR)], TARGET_SR)
            c["clips"].append(f"{CLIPS_DIR}/{name}")
            c["clip_starts"].append(round(a, 2))


def write(cfg, audio_path: Path, *, period: str, base: str, outputs: dict,
          turns: list[dict], centroids: dict, names: dict, idents: dict,
          segments: list[dict]) -> dict:
    """Собрать и записать сайдкар с клипами. Возвращает сайдкар."""
    d = sidecar_dir(cfg, period, base)
    root(cfg).mkdir(parents=True, exist_ok=True, mode=0o700)
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    min_speech = cfg.identify_min_speech
    clusters = build_clusters(turns, centroids, names, idents, segments, min_speech)
    ends = [t["end"] for t in turns] + [s.get("end") or 0 for s in segments]
    sidecar = {
        "version": VERSION,
        "source": Path(audio_path).name,
        "base": base,
        "period": period,
        "processed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "txt": str(outputs["txt"]),
        "srt": str(outputs.get("srt") or ""),
        "duration_sec": round(max(ends), 1) if ends else 0.0,
        "threshold": cfg.identify_threshold,
        "min_speech": min_speech,
        "clusters": clusters,
    }
    try:
        _cut_clips(Path(audio_path), d / CLIPS_DIR, clusters, turns)
    except Exception as e:  # noqa: BLE001 — без клипов карточки всё равно полезны
        sidecar["clips_error"] = f"{type(e).__name__}: {e}"
    save(d / FILE_NAME, sidecar)
    return sidecar


# --- переподпись транскрипта ---


def _rewrite_lines(lines: list[str], renames: dict, txt: bool) -> tuple[list[str], int]:
    """Заменить префикс «Имя: » по таблице старое→новое. Длинные имена раньше коротких:
    «Спикер 1» не должен перехватывать «Спикер 12»."""
    order = sorted(renames, key=len, reverse=True)
    out, changed = [], 0
    for line in lines:
        head, rest = "", line
        if txt:
            m = _TXT_LINE.match(line)
            if not m:
                out.append(line)
                continue
            head, rest = m.group(1), m.group(2)
        for old in order:
            if rest.startswith(old + ": "):
                rest = renames[old] + rest[len(old):]
                changed += 1
                break
        out.append(head + rest)
    return out, changed


def relabel_transcript(sidecar_path: Path) -> dict:
    """Переписать .txt/.srt текущими именами кластеров и обновить `written`."""
    path = resolve_path(sidecar_path)
    sidecar = load(path)
    renames = {}
    for c in sidecar["clusters"]:
        new = current_name(c)
        if new != c["written"]:
            renames[c["written"]] = new
    if not renames:
        return {"changed": 0, "files": []}
    files, total = [], 0
    for key, is_txt in (("txt", True), ("srt", False)):
        target = Path(sidecar.get(key) or "")
        if not sidecar.get(key) or not target.exists():
            continue
        text = target.read_text(encoding="utf-8")
        lines, changed = _rewrite_lines(text.split("\n"), renames, is_txt)
        if changed:
            target.write_text("\n".join(lines), encoding="utf-8")
            files.append(str(target))
            total += changed
    for c in sidecar["clusters"]:
        c["written"] = current_name(c)
    save(path, sidecar)
    return {"changed": total, "files": files}


def forget(sidecar_path: Path) -> Path:
    """Убрать запись из разметки: каталог с сайдкаром, клипами и векторами удаляется.
    Транскрипт и уже сохранённые в базу образцы не трогаются."""
    path = resolve_path(sidecar_path)
    rec = path.parent
    shutil.rmtree(rec, ignore_errors=True)
    period = rec.parent
    if period.exists() and not any(period.iterdir()):
        period.rmdir()
    return rec


# --- ретенция ---


def sweep(cfg, max_age: float = DEFAULT_MAX_AGE, now: Optional[float] = None) -> list[Path]:
    """Удалить каталоги записей старше `max_age` секунд (по mtime сайдкара)."""
    base = root(cfg)
    if not base.exists():
        return []
    now = now if now is not None else datetime.now().timestamp()
    removed = []
    for period in base.iterdir():
        if not period.is_dir():
            continue
        for rec in period.iterdir():
            marker = rec / FILE_NAME
            if not rec.is_dir() or not marker.exists():
                continue
            if now - marker.stat().st_mtime > max_age:
                shutil.rmtree(rec, ignore_errors=True)
                removed.append(rec)
        if not any(period.iterdir()):
            period.rmdir()
    return removed


def list_sidecars(cfg) -> list[Path]:
    """Все сайдкары, новые сверху."""
    base = root(cfg)
    if not base.exists():
        return []
    found = list(base.glob(f"*/*/{FILE_NAME}"))
    return sorted(found, key=lambda p: p.stat().st_mtime, reverse=True)
