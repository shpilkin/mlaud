"""Спайк: живая пометка «Я / не я» на одном микрофоне — что именно ломается и что чинит.

Данные — записи офлайн-звонков 12–13.09.2026 из архива (`~/ASR/Processed/AllRecords/2026-09`),
окна фраз — из `transcript.live.jsonl` папок звонков (`~/ASR/Prompter/calls`), правда о
говорящем — по содержанию реплик (см. TRUTH). Эталоны: текущая база `~/ASR/voices`
(персона «Я»: «разговорные фразы» и «начитка») и бэкап персоны «я» из замера S4
(`~/ASR/voices-backup-20260913.tar.gz`, распакованный в BACKUP).

Варианты решения:
  A   как в коде 0.13.6: сырое окно (с нулями гейта) → лучший косинус по текущим образцам «Я», порог 0.60
  A0  как в коде 0.13.3: сырое окно → центроид персоны «я» из S4 (бэкап), порог 0.60
  B   только речь (VAD = pyannote/segmentation-3.0, кадры с p(речь) > 0.5) → центроид «я» из S4;
      минимум 1.5 с речи, порог перебором
  Bn  то же, но эталон — только «начитка 45 с» (единственный неповреждённый образец текущей базы)

    HF_HUB_OFFLINE=1 poc/.venv/bin/python poc/livespk/eval.py [--backup DIR]
"""
import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "worker"))
from mlaud_worker import spkid                    # noqa: E402
from mlaud_worker.audio import load_audio         # noqa: E402

SR = 16000
ARCHIVE = Path.home() / "ASR/Processed/AllRecords/2026-09"
CALLS = Path.home() / "ASR/Prompter/calls"
VOICES = Path(os.environ.get("MLAUD_VOICES_DIR") or Path.home() / "ASR/voices")
THRESHOLDS = [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]

# Правда по содержанию реплик: user / other / mixed / None (не знаю — не считается).
TRUTH = {
    "2026-09-13_17-32-03": {(0, 6.08): "user", (6.08, 10.02): "user", (10.02, 13.86): None,
                            (13.86, 23.02): "mixed", (23.02, 26.85): "user", (26.85, 29.54): "user",
                            (29.54, 32.14): "other", (32.14, 37.94): "other", (37.94, 39.88): "user",
                            (39.88, 41.05): "user", (41.05, 45.93): None},
    "2026-09-13_17-14-06": "user",
    "2026-09-13_17-13-37": "user",
    # «реплика» — гость А говорил параллельно: окна 6.5–17.65 не знаю
    "2026-09-13_16-48-37": {(0, 6.5): "user", (17.65, 22.07): "user"},
    "2026-09-12_21-43-17": {(0.71, 4.84): "user", (4.84, 13.07): "user", (13.07, 18.37): "user",
                            (18.37, 25.47): "user", (25.47, 32.58): "mixed"},
    "2026-09-12_20-50-14": {(0.74, 4.09): "user", (4.09, 7.52): "user", (7.52, 12.55): "user",
                            (12.55, 24.7): "user", (24.7, 29.77): "user",
                            # «реплика» / «реплика» — гость Б говорит параллельно: не знаю
                            (34.43, 38.86): "mixed"},
}
# Сегменты чистых говорящих по SRT пакетной диаризации (для попарной таблицы).
SEGMENTS = [
    ("user  17-32-03 0.7-10.6", "2026-09-13_17-32-03", 0.68, 10.64),
    ("GstB  17-32-03 14.2-21.4", "2026-09-13_17-32-03", 14.196, 21.436),
    ("gsA   17-32-03 30.2-38.3", "2026-09-13_17-32-03", 30.15, 38.28),
    ("user  17-14-06 1-8", "2026-09-13_17-14-06", 1.08, 8.2),
    ("user  17-14-06 8.7-20", "2026-09-13_17-14-06", 8.72, 20.0),
    ("user  17-13-37 1-10", "2026-09-13_17-13-37", 1.0, 10.0),
    ("user  17-13-37 10-20", "2026-09-13_17-13-37", 10.0, 20.4),
    ("gsA   21-43-17 25.5-31.5", "2026-09-12_21-43-17", 25.5, 31.5),
]


class Models:
    def __init__(self):
        from pyannote.audio import Inference, Model
        self.emb_inf = Inference(Model.from_pretrained("pyannote/wespeaker-voxceleb-resnet34-LM"),
                                 window="whole", device=torch.device("cpu"))
        self.seg = Model.from_pretrained("pyannote/segmentation-3.0").eval()

    def embed(self, x: np.ndarray):
        x = np.asarray(x, dtype=np.float32).reshape(-1)
        if x.size < SR // 2:
            return None
        w = torch.from_numpy(np.ascontiguousarray(x.reshape(1, -1)))
        return spkid.normalize(np.asarray(self.emb_inf({"waveform": w, "sample_rate": SR})).reshape(-1))

    def speech(self, x: np.ndarray):
        """(p_speech по кадрам, число говорящих по кадрам, шаг кадра в сэмплах) — окно режется на куски ≤ 10 с."""
        x = np.asarray(x, dtype=np.float32).reshape(-1)
        chunk = 10 * SR
        ps, counts = [], []
        step = None
        with torch.no_grad():
            for i in range(0, max(len(x), 1), chunk):
                piece = x[i:i + chunk]
                if piece.size < SR:                     # хвост короче секунды дополняем тишиной
                    piece = np.pad(piece, (0, SR - piece.size))
                out = self.seg(torch.from_numpy(piece.reshape(1, 1, -1)))[0]   # (T, 7) log-probs
                prob = torch.exp(out).numpy()
                step = piece.size / prob.shape[0] if step is None else step
                cls = prob.argmax(axis=1)
                # классы powerset (3 спикера): 0 тишина, 1..3 один, 4..6 два
                counts.append(np.where(cls == 0, 0, np.where(cls <= 3, 1, 2)))
                ps.append(1.0 - prob[:, 0])
        return np.concatenate(ps), np.concatenate(counts), step

    def tracks(self, x: np.ndarray, thr: float = 0.5):
        """Речь каждой дорожки говорящего внутри окна (кусками ≤ 10 с, дорожки по чанкам не сшиваются —
        для окна ≤ 10 с это ровно дорожки модели). [(секунд речи, сэмплы)] по убыванию речи."""
        x = np.asarray(x, dtype=np.float32).reshape(-1)
        chunk = 10 * SR
        out = []
        with torch.no_grad():
            for i in range(0, max(len(x), 1), chunk):
                piece = x[i:i + chunk]
                if piece.size < SR:
                    piece = np.pad(piece, (0, SR - piece.size))
                prob = torch.exp(self.seg(torch.from_numpy(piece.reshape(1, 1, -1)))[0]).numpy()
                step = piece.size / prob.shape[0]
                cls = prob.argmax(axis=1)
                # powerset → активность трёх дорожек: 1,2,3 — одиночные; 4 = 1+2, 5 = 1+3, 6 = 2+3
                active = {0: {1, 4, 5}, 1: {2, 4, 6}, 2: {3, 5, 6}}
                for spk, classes in active.items():
                    idx = [j for j, c in enumerate(cls) if c in classes]
                    if not idx:
                        continue
                    parts = [piece[int(j * step):int((j + 1) * step)] for j in idx]
                    xs = np.concatenate(parts)
                    out.append((len(xs) / SR, xs))
        return sorted(out, key=lambda t: -t[0])

    def speech_only(self, x: np.ndarray, thr: float = 0.5):
        p, _, step = self.speech(x)
        n = len(x)
        keep = []
        for i, pi in enumerate(p):
            a, b = int(i * step), min(int((i + 1) * step), n)
            if pi > thr and b > a:
                keep.append(x[a:b])
        return np.concatenate(keep) if keep else np.zeros(0, dtype=np.float32)


def rms_trim(x: np.ndarray, thr: float = 0.006) -> np.ndarray:
    f = 320
    n = len(x) // f
    fr = x[:n * f].reshape(n, f)
    return fr[np.sqrt((fr ** 2).mean(1)) > thr].reshape(-1)


def load_refs(backup: Path):
    from mlaud_worker.voices import VoiceStore
    cur = VoiceStore(VOICES)
    people = cur.people()
    now = {}
    for sid in people.get("Я", {}).get("samples", []):
        meta = json.loads((cur.samples_dir / f"{sid}.json").read_text())
        now[meta.get("label", sid)] = spkid.normalize(np.load(cur.samples_dir / f"{sid}.npy"))
    old = None
    if backup and (backup / "index.json").exists():
        idx = json.loads((backup / "index.json").read_text())
        embs = [np.load(backup / "samples" / f"{sid}.npy") for sid in idx["people"]["я"]["samples"]]
        old = spkid.build_gallery({"я": embs})["я"]
    return now, old


def truth_for(base: str, t0: float, t1: float):
    t = TRUTH.get(base)
    if t is None:
        return None
    if isinstance(t, str):
        return t
    for (a, b), v in t.items():
        if abs(a - t0) < 0.05 and abs(b - t1) < 0.05:
            return v
    return None


def live_windows(base: str):
    p = CALLS / base / "transcript.live.jsonl"
    out = []
    for line in p.read_text(encoding="utf-8").splitlines():
        # у офлайн-строк "voice" дописан после закрывающей скобки — разбираем вручную
        try:
            core = json.loads(line.split('},"voice":')[0] + ("}" if '},"voice":' in line else ""))
        except json.JSONDecodeError:
            continue
        if core.get("t") == "relabel":
            continue
        out.append((core["t0"], core["t1"], core.get("label"), core["text"]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--backup", default=None, help="каталог voices из бэкапа персоны «я» (S4)")
    args = ap.parse_args()
    m = Models()
    now, old = load_refs(Path(args.backup) if args.backup else None)
    print("Текущие образцы «Я»:", ", ".join(now) or "нет", "| бэкап «я» S4:", "есть" if old is not None else "нет")
    audio = {}
    for base in TRUTH:
        audio[base] = load_audio(str(ARCHIVE / f"{base}.m4a"))

    # ---- 1. Попарно по чистым сегментам: сырые, RMS-обрезка, VAD-обрезка
    print("\n## Сегменты одного говорящего (SRT): речь по VAD и косинус к эталонам\n")
    print(f"{'сегмент':28s} {'окно':>5s} {'rms>0.006':>9s} {'VAD':>5s} | {'сырое: S4':>9s} {'начитка':>7s} | {'VAD: S4':>7s} {'начитка':>7s}")
    E = {}
    for name, base, t0, t1 in SEGMENTS:
        x = audio[base][int(t0 * SR):int(t1 * SR)]
        xr, xv = rms_trim(x), m.speech_only(x)
        e_raw, e_vad = m.embed(x), m.embed(xv)
        E[name] = e_vad
        def sc(e, ref):
            return "  n/a" if e is None or ref is None else f"{float(e @ ref):5.2f}"
        nach = now.get("начитка 45 с")
        print(f"{name:28s} {len(x)/SR:5.1f} {len(xr)/SR:9.1f} {len(xv)/SR:5.1f} | {sc(e_raw, old):>9s} {sc(e_raw, nach):>7s} | {sc(e_vad, old):>7s} {sc(e_vad, nach):>7s}")
    names = [n for n in E if E[n] is not None]
    print("\nПопарно (только речь по VAD):")
    print(" " * 30 + "".join(f"{i:>6d}" for i in range(len(names))))
    for i, a in enumerate(names):
        print(f"{i:2d} {a[:26]:26s} " + "".join(f"{float(E[a] @ E[b]):6.2f}" for b in names))

    # ---- 2. Живые окна: варианты решения
    print("\n## Живые окна фраз (t0/t1 из transcript.live.jsonl)\n")
    rows = []
    for base in TRUTH:
        for t0, t1, label, text in live_windows(base):
            tr = truth_for(base, t0, t1)
            x = audio[base][int(t0 * SR):int(t1 * SR)]
            p, counts, step = m.speech(x)
            xv = m.speech_only(x)
            speech_sec = len(xv) / SR
            two = float((counts >= 2).mean()) if counts.size else 0.0
            e_raw, e_vad = m.embed(x), m.embed(xv)
            nach = now.get("начитка 45 с")
            a = max((float(e_raw @ r) for r in now.values()), default=float("nan")) if e_raw is not None else float("nan")
            a0 = float(e_raw @ old) if (e_raw is not None and old is not None) else float("nan")
            b = float(e_vad @ old) if (e_vad is not None and old is not None) else float("nan")
            bn = float(e_vad @ nach) if (e_vad is not None and nach is not None) else float("nan")
            rows.append(dict(base=base, t0=t0, t1=t1, truth=tr, label=label, text=text, win=t1 - t0,
                             speech=speech_sec, two=two, A=a, A0=a0, B=b, Bn=bn))
    print(f"{'звонок':19s} {'окно':>11s} {'правда':>6s} {'метка':>5s} {'окно с':>6s} {'речь с':>6s} {'2 гол.':>6s} | {'A':>5s} {'A0':>5s} | {'B':>5s} {'Bn':>5s}  текст")
    for r in rows:
        print(f"{r['base'][11:]:19s} {r['t0']:5.2f}-{r['t1']:5.2f} {str(r['truth']):>6s} {str(r['label']):>5s} {r['win']:6.1f} {r['speech']:6.1f} {r['two']*100:5.0f}% | "
              f"{r['A']:5.2f} {r['A0']:5.2f} | {r['B']:5.2f} {r['Bn']:5.2f}  {r['text'][:48]}")

    # ---- 2b. Смешанные окна: дорожки говорящих модели сегментации → отдельные эмбеддинги
    print("\n## Смешанные окна: разбиение по дорожкам говорящих (segmentation-3.0) внутри окна\n")
    for r in rows:
        if r["truth"] != "mixed":
            continue
        x = audio[r["base"]][int(r["t0"] * SR):int(r["t1"] * SR)]
        tracks = m.tracks(x)
        print(f"{r['base'][11:]} {r['t0']:.2f}-{r['t1']:.2f}: {r['text'][:60]}")
        for k, (sec, xs) in enumerate(tracks):
            e = m.embed(xs)
            sc_old = f"{float(e @ old):.2f}" if (e is not None and old is not None) else "n/a"
            sc_n = f"{float(e @ nach):.2f}" if (e is not None and nach is not None) else "n/a"
            print(f"    дорожка {k}: речь {sec:4.1f} с | к «я» S4 {sc_old} | к начитке {sc_n}")

    # ---- 3. Сводка по порогам
    print("\n## Сводка: доля окон пользователя, помеченных «Я», и ложных «Я» на чужих/смешанных окнах\n")
    def summary(key, thr, min_speech):
        ok = tot = bad = badtot = skipped = 0
        for r in rows:
            if r["truth"] is None:
                continue
            eligible = r["speech"] >= min_speech if min_speech else r["win"] >= 2.0
            if not eligible or np.isnan(r[key]):
                if r["truth"] == "user":
                    skipped += 1
                continue
            is_self = r[key] >= thr
            if r["truth"] == "user":
                tot += 1; ok += is_self
            else:
                badtot += 1; bad += is_self
        return ok, tot, skipped, bad, badtot
    print("| вариант | порог | свои: Я | свои: не Я | свои без пометки (короткие) | чужие+смесь: ложное Я |")
    print("|---|---|---|---|---|---|")
    for key, min_speech, thrs in (("A", None, [0.60]), ("A0", None, [0.60]), ("B", 1.5, THRESHOLDS), ("Bn", 1.5, THRESHOLDS)):
        for thr in thrs:
            ok, tot, skipped, bad, badtot = summary(key, thr, min_speech)
            print(f"| {key} | {thr:.2f} | {ok}/{tot} | {tot-ok}/{tot} | {skipped} | {bad}/{badtot} |")
    return 0


if __name__ == "__main__":
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    sys.exit(main())
