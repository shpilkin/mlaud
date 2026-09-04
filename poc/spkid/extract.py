"""Шаг 1 замера: диаризация + центроиды спикеров + образцы аудио для разметки.

Прогоняет записи из архива, для каждой сохраняет:
  data/<slug>.npy   — центроиды кластеров (N, 256), порядок = labels в json
  data/<slug>.json  — метаданные файла и кластеров
  clips/<slug>/…    — по 3 фрагмента на кластер, чтобы человек мог послушать и назвать

Данные биометрические, поэтому пишем в ~/ASR/spkid-eval (локально, вне репозитория и вне iCloud).
Прогон возобновляемый: файл с готовым json пропускается.
"""

import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "worker"))
from mlaud_worker.audio import TARGET_SR, load_audio  # noqa: E402

SRC = Path(os.environ.get("SPKID_SRC", Path.home() / "ASR/Processed/AllRecords"))
OUT = Path(os.environ.get("SPKID_OUT", Path.home() / "ASR/spkid-eval"))
MIN_DURATION = 60.0     # короче — это дымовые прогоны и диктовки, центроид из них шумовой
CLIPS_PER_SPK = 3
CLIP_SEC = 6.0
MIN_TURN_SEC = 3.0      # для образца; если таких реплик мало, планка опускается до 1.5
EXTS = (".m4a", ".mp3", ".wav", ".aac", ".aiff", ".caf")


def slug_for(path: Path) -> str:
    """Имя файла + хвост хеша пути.

    Одного stem мало: APFS регистро-нечувствительна, и «планёрка.mp3» с
    «Планёрка.m4a» (одна встреча в двух форматах) писались бы в один и тот же
    json — второй файл молча пропускался как уже готовый.
    """
    return f"{path.stem}__{hashlib.sha1(str(path).encode()).hexdigest()[:8]}"


def probe(path: Path) -> dict:
    """Частота и число каналов исходника (для догадки «телефон/ВКС» в разметке)."""
    out = {"src_sr": None, "src_channels": None, "duration": None}
    try:
        info = subprocess.run(["afinfo", str(path)], capture_output=True, text=True).stdout
    except FileNotFoundError:
        return out
    for line in info.splitlines():
        s = line.strip()
        if s.startswith("estimated duration"):
            out["duration"] = float(s.split(":")[1].strip().split()[0])
        elif s.startswith("Data format"):
            body = s.split(":", 1)[1]
            for part in body.split(","):
                p = part.strip()
                if p.endswith("ch"):
                    out["src_channels"] = int(p.split()[0])
                elif p.endswith("Hz"):
                    out["src_sr"] = int(float(p.split()[0]))
    return out


def pick_clip_windows(turns: list[dict]) -> list[tuple[float, float]]:
    """Три окна, разнесённые по таймлайну кластера, а не три самые длинные реплики.

    Разнесение принципиально: если pyannote слил двух людей в один кластер, образцы
    из разных мест это покажут, а «три самые длинные» — скорее спрячут.
    """
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


def process(path: Path, pipeline, torch) -> dict | None:
    meta = probe(path)
    if meta["duration"] is not None and meta["duration"] < MIN_DURATION:
        print(f"  пропуск (короткий, {meta['duration']:.0f} c)")
        return None

    wav = load_audio(str(path))
    dur = len(wav) / TARGET_SR
    if dur < MIN_DURATION:
        print(f"  пропуск (короткий, {dur:.0f} c)")
        return None

    t0 = time.time()
    annotation, centroids = pipeline(
        {"waveform": torch.from_numpy(wav).unsqueeze(0), "sample_rate": TARGET_SR},
        return_embeddings=True,
    )
    elapsed = time.time() - t0

    by_label: dict[str, list[dict]] = {}
    for segment, _, label in annotation.itertracks(yield_label=True):
        by_label.setdefault(str(label), []).append(
            {"start": float(segment.start), "end": float(segment.end)}
        )

    labels = list(annotation.labels())
    if centroids is None:
        print("  центроидов нет (OracleClustering?) — пропуск")
        return None

    slug = slug_for(path)
    clip_dir = OUT / "clips" / slug
    clip_dir.mkdir(parents=True, exist_ok=True)

    speakers = []
    for i, label in enumerate(labels):
        turns = by_label.get(label, [])
        norm = float(np.linalg.norm(centroids[i]))
        speech = sum(t["end"] - t["start"] for t in turns)
        clips = []
        # Нулевой центроид = добивка np.pad, когда спикеров в аннотации больше,
        # чем кластеров (speaker_diarization.py:614). Косинус с нулём не определён.
        for j, (a, b) in enumerate(pick_clip_windows(turns)):
            name = f"{label}_{j}.wav"
            sf.write(clip_dir / name, wav[int(a * TARGET_SR):int(b * TARGET_SR)], TARGET_SR)
            clips.append({"file": name, "start": round(a, 2), "end": round(b, 2)})
        speakers.append({
            "label": label,
            "index": i,
            "speech_sec": round(speech, 1),
            "n_turns": len(turns),
            "centroid_norm": round(norm, 4),
            "padded": norm < 1e-6,
            "clips": clips,
        })

    rec = {
        "slug": slug,
        "name": path.name,
        "path": str(path),
        "duration": round(dur, 1),
        "src_sr": meta["src_sr"],
        "src_channels": meta["src_channels"],
        "diarize_sec": round(elapsed, 1),
        "speakers": speakers,
    }
    np.save(OUT / "data" / f"{slug}.npy", centroids)
    (OUT / "data" / f"{slug}.json").write_text(
        json.dumps(rec, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"  {len(labels)} кластеров, {elapsed:.0f} c на {dur:.0f} c аудио "
          f"({dur / max(elapsed, 0.1):.0f}x)")
    return rec


def main() -> int:
    (OUT / "data").mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in SRC.rglob("*") if p.suffix.lower() in EXTS)
    print(f"источник: {SRC}\nвыход:    {OUT}\nфайлов:   {len(files)}\n")

    import torch
    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1")
    if pipeline is None:
        print("pyannote вернул None: нет модели в кэше или не принято лицензионное условие")
        return 1
    device = os.environ.get("SPKID_DEVICE", "mps")
    pipeline.to(torch.device(device))
    print(f"пайплайн загружен на {device}\n")

    done = failed = 0
    for n, path in enumerate(files, 1):
        print(f"[{n}/{len(files)}] {path.name}")
        if (OUT / "data" / f"{slug_for(path)}.json").exists():
            print("  уже есть, пропуск")
            done += 1
            continue
        try:
            if process(path, pipeline, torch) is not None:
                done += 1
        except Exception as e:  # один битый файл не должен ронять сорокаминутный прогон
            failed += 1
            print(f"  ОШИБКА: {type(e).__name__}: {e}")
    print(f"\nготово: {done} разобрано, {failed} с ошибкой")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
