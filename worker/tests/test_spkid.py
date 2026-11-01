"""Узнавание голоса: чистые функции + регрессия против реального замера (poc/spkid)."""

import importlib.util
import math
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import pytest

from mlaud_worker import spkid
from mlaud_worker.spkid import CONFIDENT, build_gallery, identify, match, normalize

DIM = 8


def unit(i: int) -> np.ndarray:
    v = np.zeros(DIM)
    v[i] = 1.0
    return v


def at_cosine(base: np.ndarray, other: np.ndarray, cos: float) -> np.ndarray:
    """Вектор с заданным косинусом к `base` в плоскости (base, other)."""
    return cos * base + math.sqrt(1 - cos * cos) * other


# --- слой 1 ---


def test_normalize_zero_is_none():
    assert normalize(np.zeros(DIM)) is None
    n = normalize(np.array([3.0, 4.0]))
    assert np.allclose(n, [0.6, 0.8])


def test_build_gallery_normalizes_each_sample_then_mean():
    # два образца одной длины в разные стороны → центроид посередине;
    # масштаб образца не влияет (сначала нормируем, потом усредняем)
    g = build_gallery({"A": [unit(0) * 5.0, unit(1) * 0.1]})
    assert np.allclose(g["A"], normalize(unit(0) + unit(1)))
    # нулевые образцы и люди без валидных образцов выпадают
    g = build_gallery({"A": [unit(0), np.zeros(DIM)], "B": [np.zeros(DIM)]})
    assert list(g) == ["A"]


def test_match_picks_best_and_applies_threshold():
    gallery = build_gallery({"A": [unit(0)], "B": [unit(1)]})
    probe = at_cosine(unit(0), unit(1), 0.9)   # 0.9 к A, ~0.44 к B
    assert match(probe * 2.7, gallery, 0.75) == ("A", pytest.approx(0.9))   # сырой масштаб не важен
    name, score = match(probe, gallery, 0.95)
    assert name is None and score == pytest.approx(0.9)               # ниже порога — но счёт отдаём
    assert match(probe, gallery, 0.9)[0] == "A"                       # порог включительно


def test_match_degenerate_inputs():
    assert match(unit(0), {}, 0.5) == (None, 0.0)
    assert match(np.zeros(DIM), build_gallery({"A": [unit(0)]}), 0.5) == (None, 0.0)


# --- слой 2 ---


def test_identify_short_cluster_never_named():
    gallery = build_gallery({"A": [unit(0)]})
    res = identify({"S0": (unit(0), 29.9), "S1": (unit(0), 30.0)}, gallery, 0.70, 30.0)
    assert res["S0"].name is None and res["S0"].display is None
    assert res["S0"].score == 0.0                     # не сравнивали вовсе
    assert res["S1"].name == "A" and res["S1"].sure


def test_identify_bands():
    # три разных человека, чтобы конфликт-резолвер не вмешивался
    gallery = build_gallery({"A": [unit(0)], "B": [unit(2)], "C": [unit(4)]})
    sure = at_cosine(unit(0), unit(1), CONFIDENT)
    unsure = at_cosine(unit(2), unit(3), 0.76)
    below = at_cosine(unit(4), unit(5), 0.74)
    res = identify({"s": (sure, 60), "u": (unsure, 60), "b": (below, 60)}, gallery, 0.75, 30)
    assert res["s"].display == "A"
    assert res["u"].display == "B(?)"
    assert res["b"].display is None and res["b"].score == pytest.approx(0.74)


def test_identify_conflict_goes_to_higher_score_other_stays_anonymous():
    gallery = build_gallery({"A": [unit(0)], "B": [unit(2)]})
    strong = at_cosine(unit(0), unit(1), 0.95)
    weak = at_cosine(unit(0), unit(1), 0.85)   # к A 0.85, но ко всем остальным хуже
    res = identify({"x": (weak, 60), "y": (strong, 60)}, gallery, 0.70, 30)
    assert res["y"].name == "A"
    assert res["x"].name is None                      # не «второе лучшее», а без имени
    assert res["x"].score == pytest.approx(0.85)      # счёт сохранён для диагностики


def test_identify_empty_gallery():
    res = identify({"x": (unit(0), 100)}, {}, 0.5, 30)
    assert res["x"].name is None and res["x"].score == 0.0


# --- регрессия против замера ---

EVAL = Path.home() / "ASR/spkid-eval"
ANALYZE = Path(__file__).resolve().parents[2] / "poc/spkid/analyze.py"
THRESHOLDS = (0.70, 0.75, 0.80)
CELLS = ("верно названо", "перепутаны люди", "чужого приняли за своего",
         "свой не узнан", "корректный отказ")


def _load_analyze():
    spec = importlib.util.spec_from_file_location("spkid_analyze", ANALYZE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _loo_with_worker_code(clusters, group, min_speech):
    """Тот же leave-one-file-out, что в analyze.loo(), но через build_gallery()/match()."""
    cs = [c for c in clusters if c["speech_sec"] >= min_speech]
    stats = {t: Counter() for t in THRESHOLDS}
    for slug in sorted({c["slug"] for c in cs}):
        gid = group[slug]
        samples = defaultdict(list)
        for c in cs:
            if group[c["slug"]] != gid:      # та же встреча в другом формате — не галерея
                samples[c["name"]].append(c["emb"])
        if not samples:
            continue
        gallery = build_gallery(samples)
        for c in (x for x in cs if x["slug"] == slug):
            known = c["name"] in gallery
            for t in THRESHOLDS:
                name, _ = match(c["emb"], gallery, t)
                s = stats[t]
                if name is not None:
                    if not known:
                        s["чужого приняли за своего"] += 1
                    elif name == c["name"]:
                        s["верно названо"] += 1
                    else:
                        s["перепутаны люди"] += 1
                else:
                    s["корректный отказ" if not known else "свой не узнан"] += 1
    return stats


@pytest.mark.skipif(not (EVAL / "labels.json").exists() or not ANALYZE.exists(),
                    reason="данных замера (~/ASR/spkid-eval, биометрия вне репозитория) нет")
def test_matching_reproduces_measurement_table():
    """Источник истины — analyze.py на актуальном labels.json, а не числа в документе."""
    analyze = _load_analyze()
    clusters, durations, _ = analyze.load()
    assert len(clusters) >= 4, "размеченных кластеров слишком мало"
    group = analyze.recording_groups(durations)
    min_speech = analyze.LONG_ENOUGH

    reference = analyze.loo(clusters, group, list(THRESHOLDS), min_speech)
    ours = _loo_with_worker_code(clusters, group, min_speech)

    print(f"\nleave-one-file-out, кластеры с речью ≥ {min_speech:.0f} c (worker / analyze.py):")
    print("| порог | " + " | ".join(CELLS) + " |")
    for t in THRESHOLDS:
        print(f"| {t:.2f} | " + " | ".join(
            f"{ours[t][k]} / {reference[t][k]}" for k in CELLS) + " |")

    for t in THRESHOLDS:
        for k in CELLS:
            assert abs(ours[t][k] - reference[t][k]) <= 1, f"порог {t}, «{k}»"


@pytest.mark.skipif(not (EVAL / "labels.json").exists() or not ANALYZE.exists(),
                    reason="данных замера нет")
def test_measurement_gallery_is_zero_free():
    """Нулевые центроиды-добивки не должны попасть в галерею и не должны матчиться."""
    analyze = _load_analyze()
    clusters, _, _ = analyze.load()
    for c in clusters:
        assert spkid.normalize(c["emb"]) is not None
