"""Спайк S4 (OQ-15): узнаётся ли голос на коротких клипах — для живой пометки «Я».

Клипы `~/ASR/spkid-eval/clips/<slug>/` (по три на кластер, 16 кГц mono) → эмбеддинг той же
моделью, что считает диаризация (`pyannote/wespeaker-voxceleb-resnet34-LM`, окно = весь
клип) → матчинг `spkid.match` против галереи «все файлы кроме этого» (leave-one-file-out,
группировка одинаковых записей как в analyze.py). Галерея — центроиды кластеров с речью
≥ 30 с (в базу голосов попадают только такие, FR-8.9).

    HF_HUB_OFFLINE=1 poc/.venv/bin/python poc/spkid/short_clips.py

Отчёт — `~/ASR/spkid-eval/short_clips.md` и stdout.
"""

import json
import os
import statistics
import sys
import time
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent.parent / "worker"))

from analyze import LONG_ENOUGH, OUT, load, recording_groups  # noqa: E402
from mlaud_worker import spkid  # noqa: E402

THRESHOLDS = [0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85]
SELF = "я"
CPU_SAMPLE = 40   # столько клипов считаем ещё и на CPU ради времени
BUCKETS = [(0.0, 2.0, "< 2 с"), (2.0, 4.0, "2–4 с"), (4.0, 99.0, "≥ 4 с")]


def embedder(device: str):
    from pyannote.audio import Inference, Model

    model = Model.from_pretrained("pyannote/wespeaker-voxceleb-resnet34-LM")
    return Inference(model, window="whole", device=torch.device(device))


def embed(inf, path: Path):
    wav, sr = sf.read(path, dtype="float32")
    if wav.ndim > 1:
        wav = wav.mean(axis=1)
    t0 = time.perf_counter()
    emb = inf({"waveform": torch.from_numpy(wav).unsqueeze(0), "sample_rate": sr})
    dt = time.perf_counter() - t0
    return np.asarray(emb, dtype=np.float64).reshape(-1), dt, len(wav) / sr


def clip_list(clusters):
    """Клипы размеченных, не смешанных кластеров: (slug, label, name, файл)."""
    by_key = {(c["slug"], c["label"]): c for c in clusters}
    out = []
    for p in sorted((OUT / "data").glob("*.json")):
        rec = json.loads(p.read_text(encoding="utf-8"))
        for sp in rec["speakers"]:
            c = by_key.get((rec["slug"], sp["label"]))
            if c is None:
                continue
            for clip in sp.get("clips", []):
                f = OUT / "clips" / rec["slug"] / clip["file"]
                if f.is_file():
                    out.append((rec["slug"], sp["label"], c["name"], f))
    return out


def gallery_for(clusters, group, gid):
    src = defaultdict(list)
    for c in clusters:
        if group[c["slug"]] != gid and c["speech_sec"] >= LONG_ENOUGH:
            src[c["name"]].append(c["emb"])
    return spkid.build_gallery(src)


def main() -> int:
    clusters, durations, _ = load()
    group = recording_groups(durations)
    # Запись, сохранённая в двух форматах, — один файл: вторая копия не тестируется и не
    # удваивает вес в галерее (представитель группы — slug, у которого group[slug] == slug).
    twins = sorted({c["slug"] for c in clusters if group[c["slug"]] != c["slug"]})
    clusters = [c for c in clusters if group[c["slug"]] == c["slug"]]
    clips = clip_list(clusters)
    if not clips:
        print("клипов нет — сначала extract.py и разметка", file=sys.stderr)
        return 1
    inf = embedder("mps" if torch.backends.mps.is_available() else "cpu")
    rows = []          # по клипу: name, self, known, duration, best_name, best_score
    times = []
    for slug, label, name, f in clips:
        emb, dt, dur = embed(inf, f)
        times.append(dt)
        gallery = gallery_for(clusters, group, group[slug])
        best_name, best = spkid.match(emb, gallery, -1.0)   # без порога: лучший и его косинус
        unit = spkid.normalize(emb)
        self_score = float(gallery[SELF] @ unit) if SELF in gallery and unit is not None else None
        rows.append({"name": name, "self": name == SELF, "known": name in gallery,
                     "dur": dur, "best": best_name, "score": best, "self_score": self_score,
                     "slug": slug})
    cpu_times = []
    inf_cpu = embedder("cpu")
    for _, _, _, f in clips[:CPU_SAMPLE]:
        cpu_times.append(embed(inf_cpu, f)[1])

    lines = []
    out = lines.append
    out("# S4: короткие клипы против галереи «все файлы кроме этого»\n")
    durs = [r["dur"] for r in rows]
    out(f"Клипов: **{len(rows)}** из {len({r['slug'] for r in rows})} записей; длительность "
        f"{min(durs):.1f}–{max(durs):.1f} с, медиана {statistics.median(durs):.1f} с. "
        f"Своих («я»): {sum(r['self'] for r in rows)}, других известных: "
        f"{sum(1 for r in rows if not r['self'] and r['known'])}, чужих для галереи: "
        f"{sum(1 for r in rows if not r['known'])}.")
    if twins:
        out(f"Исключены копии тех же записей в другом формате: {', '.join(twins)}.")
    out(f"Эмбеддинг клипа: MPS медиана {statistics.median(times)*1000:.0f} мс "
        f"(макс {max(times)*1000:.0f}), CPU медиана {statistics.median(cpu_times)*1000:.0f} мс "
        f"на {len(cpu_times)} клипах.\n")

    out("## По порогу\n")
    out("Свой голос — главный сценарий: «верно» = «я», «чужое имя» = любое другое имя, "
        "«без имени» = ниже порога. Чужие для галереи — люди, которых в остальных файлах "
        "нет: единственно верный ответ — отказ.\n")
    out("| порог | свой: верно | свой: чужое имя | свой: без имени | известные: верно | "
        "известные: чужое имя | известные: без имени | чужие: приняты | чужие: отказ | "
        "**неверных имён всего** |")
    out("|---|---|---|---|---|---|---|---|---|---|")
    summary = {}
    for t in THRESHOLDS:
        s = defaultdict(int)
        for r in rows:
            accepted = r["score"] >= t and r["best"] is not None
            if r["self"]:
                key = "s_ok" if accepted and r["best"] == SELF else ("s_wrong" if accepted else "s_none")
            elif r["known"]:
                key = "k_ok" if accepted and r["best"] == r["name"] else ("k_wrong" if accepted else "k_none")
            else:
                key = "u_wrong" if accepted else "u_ok"
            s[key] += 1
        wrong = s["s_wrong"] + s["k_wrong"] + s["u_wrong"]
        n_self = s["s_ok"] + s["s_wrong"] + s["s_none"]
        summary[t] = (s["s_ok"] / n_self if n_self else 0.0, wrong)
        out(f"| {t:.2f} | {s['s_ok']} | {s['s_wrong']} | {s['s_none']} | {s['k_ok']} | "
            f"{s['k_wrong']} | {s['k_none']} | {s['u_wrong']} | {s['u_ok']} | **{wrong}** |")

    out("\n## Свой голос по длительности клипа\n")
    out("| длительность | клипов | " + " | ".join(f"верно при {t:.2f}" for t in (0.60, 0.70, 0.75, 0.80)) + " |")
    out("|---|---|" + "---|" * 4)
    for lo, hi, title in BUCKETS:
        sel = [r for r in rows if r["self"] and lo <= r["dur"] < hi]
        if not sel:
            continue
        cells = []
        for t in (0.60, 0.70, 0.75, 0.80):
            ok = sum(1 for r in sel if r["score"] >= t and r["best"] == SELF)
            cells.append(f"{ok}/{len(sel)}")
        out(f"| {title} | {len(sel)} | " + " | ".join(cells) + " |")

    out("\n## Режим «Я / не я»: косинус только к своему центроиду\n")
    out("Галерея та же, но сравнение одно — с центроидом «я»; чужие имена тут не ставятся "
        "вовсе. «Ложное Я» — чужой клип (известный или незнакомый), принятый за свой.\n")
    out("| порог | свой: Я | свой: не узнан | чужие: ложное Я | чужие: верно не Я | доля своих | доля ложных Я |")
    out("|---|---|---|---|---|---|---|")
    scored = [r for r in rows if r["self_score"] is not None]
    for t in THRESHOLDS:
        s_ok = sum(1 for r in scored if r["self"] and r["self_score"] >= t)
        s_no = sum(1 for r in scored if r["self"] and r["self_score"] < t)
        o_bad = sum(1 for r in scored if not r["self"] and r["self_score"] >= t)
        o_ok = sum(1 for r in scored if not r["self"] and r["self_score"] < t)
        out(f"| {t:.2f} | {s_ok} | {s_no} | {o_bad} | {o_ok} | {s_ok/(s_ok+s_no)*100:.0f} % | "
            f"{o_bad/(o_bad+o_ok)*100:.1f} % |")
    out("\nСвой голос по длительности в режиме «Я / не я»:\n")
    out("| длительность | клипов | " + " | ".join(f"Я при {t:.2f}" for t in (0.55, 0.60, 0.65, 0.70)) + " |")
    out("|---|---|" + "---|" * 4)
    for lo, hi, title in BUCKETS:
        sel = [r for r in scored if r["self"] and lo <= r["dur"] < hi]
        if not sel:
            continue
        out(f"| {title} | {len(sel)} | " + " | ".join(
            f"{sum(1 for r in sel if r['self_score'] >= t)}/{len(sel)}" for t in (0.55, 0.60, 0.65, 0.70)) + " |")
    out(f"\nЧужие клипы с косинусом к «я» ≥ 0.55: "
        + (", ".join(f"{r['name']} ({r['self_score']:.2f}, {r['dur']:.1f} с)"
                     for r in sorted(scored, key=lambda r: -r['self_score']) if not r['self'] and r['self_score'] >= 0.55) or "нет"))

    out("\n## Распределение лучшего косинуса\n")
    def q(vals):
        if not vals:
            return "—"
        a = np.percentile(vals, [10, 50, 90])
        return f"p10 {a[0]:.2f} · медиана {a[1]:.2f} · p90 {a[2]:.2f}"
    out(f"- свой, лучший = «я»: {q([r['score'] for r in rows if r['self'] and r['best'] == SELF])}")
    out(f"- свой, лучший ≠ «я»: {q([r['score'] for r in rows if r['self'] and r['best'] != SELF])} "
        f"(таких {sum(1 for r in rows if r['self'] and r['best'] != SELF)})")
    out(f"- известные, лучший верный: {q([r['score'] for r in rows if not r['self'] and r['known'] and r['best'] == r['name']])}")
    out(f"- чужие для галереи: {q([r['score'] for r in rows if not r['known']])}")

    out("\n## Гейт\n")
    zero = [t for t in THRESHOLDS if summary[t][1] == 0]
    if zero:
        best_t = min(zero)
        out(f"Порогов без единого неверного имени: {', '.join(f'{t:.2f}' for t in zero)}; "
            f"на {best_t:.2f} свой голос верно на {summary[best_t][0]*100:.0f} % клипов "
            f"({'гейт ≥ 90 % взят' if summary[best_t][0] >= 0.9 else 'гейт ≥ 90 % не взят'}).")
    else:
        out("Ни один порог не даёт нуля неверных имён.")
    out("")
    text = "\n".join(lines)
    (OUT / "short_clips.md").write_text(text, encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    sys.exit(main())
