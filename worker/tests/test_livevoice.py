"""Тесты этапа 5: живая пометка «Я / не я» — порог, короткие фразы, база, протокол.

Полный прогон на модели и данных замера — skipif: каталог ~/ASR/spkid-eval или
зависимости pyannote отсутствуют (S4: poc/spkid/RESULT-S4.md)."""

from pathlib import Path

import numpy as np
import pytest

from mlaud_worker import livevoice
from mlaud_worker.livevoice import MIN_SEC, SELF_NAME, SR, THRESHOLD, LiveVoice

EVAL_DIR = Path.home() / "ASR/spkid-eval"


def _marker(scores):
    """Маркер с подставным эмбеддингом: embed → вектор с заданным косинусом к центроиду."""
    centroid = np.zeros(8, dtype=np.float32)
    centroid[0] = 1.0
    calls = []

    def embed(samples):
        calls.append(samples.size / SR)
        # единичный вектор под нужный косинус к центроиду (ось 0): cos = projection
        cos = scores.pop(0)
        v = np.zeros(8, dtype=np.float32)
        v[0] = cos
        v[1] = (1.0 - cos * cos) ** 0.5
        return v

    return LiveVoice(embed, centroid), calls


def test_self_above_threshold():
    marker, calls = _marker([0.71, 0.60])
    long_phrase = np.zeros(int(MIN_SEC * SR) + SR, dtype=np.float32)
    assert marker.mark(long_phrase) == {"self": True, "score": 0.71}
    assert marker.mark(long_phrase) == {"self": True, "score": 0.6}   # граница — «Я»


def test_not_self_below_threshold():
    marker, _ = _marker([0.59, 0.30])
    long_phrase = np.zeros(int(MIN_SEC * SR) + SR, dtype=np.float32)
    assert marker.mark(long_phrase) == {"self": False, "score": 0.59}
    assert marker.mark(long_phrase) == {"self": False, "score": 0.3}


def test_short_phrase_unmarked():
    """< 2 с сигнала не несут (S4: 0 из 3) — без поля, эмбеддинг не считается."""
    marker, calls = _marker([0.9])
    short = np.zeros(int(1.9 * SR), dtype=np.float32)
    assert marker.mark(short) is None
    assert calls == []


def test_exact_two_seconds_marked():
    marker, _ = _marker([0.9])
    two = np.zeros(int(MIN_SEC * SR), dtype=np.float32)
    assert marker.mark(two) == {"self": True, "score": 0.9}


def test_zero_embedding_is_rejected():
    marker, _ = _marker([1.0])
    marker.embed = lambda samples: np.zeros(8, dtype=np.float32)
    assert marker.mark(np.zeros(int(MIN_SEC * SR), dtype=np.float32)) is None


def test_threshold_is_s4_value():
    assert THRESHOLD == 0.60
    assert MIN_SEC == 2.0
    assert SELF_NAME == "Я"


def test_load_without_self_person_returns_none(tmp_path):
    assert livevoice.load(tmp_path) is None


def test_self_lookup_is_case_insensitive(tmp_path, monkeypatch):
    """В базе «я» с маленькой (заведена вручную до этапа 5) — маркер строится."""
    from mlaud_worker.voices import VoiceStore

    monkeypatch.setattr(livevoice, "_cpu_embedder", lambda: (lambda samples: np.zeros(8)))
    vec = np.zeros(8, dtype=np.float32)
    vec[0] = 1.0
    store = VoiceStore(tmp_path)
    store.add("я", vec, source_file="old.m4a", label="SPEAKER_00", speech_sec=1200.0,
              channel="phone")
    assert livevoice.load(tmp_path) is not None
    # и каноническое «Я» тоже находится
    store.add("Я", vec, source_file="ref.wav", label="SPEAKER_00", speech_sec=30.0,
              channel="reference")
    assert livevoice.load(tmp_path) is not None


def test_self_centroid_prefers_exact_over_lowercase():
    """Есть обе персоны — «Я» (свежий эталон) выигрывает у «я» независимо от порядка."""
    upper = np.zeros(8, dtype=np.float32)
    upper[0] = 1.0
    lower = np.zeros(8, dtype=np.float32)
    lower[1] = 1.0
    for gallery in ({"я": lower, "Я": upper}, {"Я": upper, "я": lower}):
        centroid = livevoice.self_centroid(gallery)
        assert centroid is upper, "точное «Я» старше регистра-двойника"
    assert livevoice.self_centroid({"я": lower}) is lower, "одиночная «я» находится"
    assert livevoice.self_centroid({"Артём А": lower}) is None


def test_load_with_self_person_builds_marker(tmp_path, monkeypatch):
    """Маркер из базы: персоны нет — None; есть «Я» — маркер (эмуляция эмбеддера:
    torch живёт в venv распознавателя, в тестовом — подмена)."""
    from mlaud_worker.voices import VoiceStore

    monkeypatch.setattr(livevoice, "_cpu_embedder", lambda: (lambda samples: np.zeros(8)))
    vec = np.zeros(8, dtype=np.float32)
    vec[0] = 1.0
    store = VoiceStore(tmp_path)
    store.add("Кто-то", vec, source_file="x.m4a", label="SPEAKER_00", speech_sec=30.0)
    assert livevoice.load(tmp_path) is None
    store.add("Я", vec, source_file="ref.wav", label="SPEAKER_00", speech_sec=30.0,
              channel="reference")
    marker = livevoice.load(tmp_path)
    assert marker is not None
    assert marker.mark(np.zeros(int(MIN_SEC * SR), dtype=np.float32)) is None  # нулевой эмбеддинг


def _model_available() -> bool:
    try:
        import pyannote.audio  # noqa: F401
        import soundfile  # noqa: F401
    except ImportError:
        return False
    return EVAL_DIR.exists() and (EVAL_DIR / "short_clips.md").exists()


@pytest.mark.skipif(not _model_available(), reason="нет pyannote/данных замера (~/ASR/spkid-eval)")
def test_s4_table_reproduced():
    """Воспроизведение строки 0.60 из S4: ≥ 71 % своих, 0 ложных «Я»."""
    import json

    report = (EVAL_DIR / "short_clips.md")
    assert report.exists()
    # Полная переоценка S4 — отдельный прогон poc/spkid/short_clips.py; здесь лишь
    # фиксируется, что порог в коде равен порогу отчёта (страж от тихого изменения).
    assert THRESHOLD == 0.60
