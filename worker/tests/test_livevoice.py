"""Тесты этапа 5: живая пометка «Я / не я» — вырезка речи, порог, база, протокол.

Полный прогон на модели и данных — skipif: зависимости pyannote отсутствуют
(замеры: poc/spkid/RESULT-S4.md, poc/livespk/RESULT.md)."""

from pathlib import Path

import numpy as np
import pytest

from mlaud_worker import livevoice
from mlaud_worker.livevoice import MIN_SPEECH_SEC, SELF_NAME, SR, THRESHOLD, LiveVoice

EVAL_DIR = Path.home() / "ASR/spkid-eval"


def _marker(scores, speech_sec=3.0):
    """Маркер с подставным эмбеддингом и вырезкой: embed → вектор с заданным
    косинусом к образцу; дорожка речи всегда одна, заданной длины."""
    ref = np.zeros(8, dtype=np.float32)
    ref[0] = 1.0
    calls = []

    def embed(samples):
        calls.append(samples.size / SR)
        # единичный вектор под нужный косинус к образцу (ось 0): cos = projection
        cos = scores.pop(0)
        v = np.zeros(8, dtype=np.float32)
        v[0] = cos
        v[1] = (1.0 - cos * cos) ** 0.5
        return v

    tracks = lambda samples: [(speech_sec, samples)]
    return LiveVoice(embed, tracks, [ref]), calls


def test_self_above_threshold():
    marker, _ = _marker([0.71, 0.40])
    phrase = np.zeros(int(3 * SR), dtype=np.float32)
    assert marker.mark(phrase) == {"self": True, "score": 0.71, "speech": 3.0}
    assert marker.mark(phrase) == {"self": True, "score": 0.4, "speech": 3.0}   # граница — «Я»


def test_not_self_below_threshold():
    marker, _ = _marker([0.39, 0.30])
    phrase = np.zeros(int(3 * SR), dtype=np.float32)
    assert marker.mark(phrase) == {"self": False, "score": 0.39, "speech": 3.0}
    assert marker.mark(phrase) == {"self": False, "score": 0.3, "speech": 3.0}


def test_too_little_speech_unmarked():
    """Речи в доминирующей дорожке < 1.5 с — без пометки, эмбеддинг не считается."""
    marker, calls = _marker([0.9], speech_sec=1.49)
    assert marker.mark(np.zeros(int(3 * SR), dtype=np.float32)) is None
    assert calls == []


def test_no_speech_track_unmarked():
    """Гейт съел всё окно — дорожек нет, пометки нет."""
    marker, _ = _marker([0.9])
    marker.speech_tracks = lambda samples: []
    assert marker.mark(np.zeros(int(3 * SR), dtype=np.float32)) is None


def test_exact_min_speech_marked():
    marker, _ = _marker([0.9], speech_sec=MIN_SPEECH_SEC)
    assert marker.mark(np.zeros(int(3 * SR), dtype=np.float32)) == \
        {"self": True, "score": 0.9, "speech": 1.5}


def test_dominant_track_wins():
    """Метка — по дорожке с максимумом речи: короткая вставка «своего» в чужой
    реплике не вытягивает окно в «Я»."""
    seen = []
    mine = np.zeros(8, dtype=np.float32); mine[0] = 1.0
    theirs = np.zeros(8, dtype=np.float32); theirs[1] = 1.0

    def embed(samples):
        seen.append(samples)
        return theirs                      # эмбеддинг совпал с «чужим» направлением

    x = np.zeros(int(5 * SR), dtype=np.float32)
    short_mine = np.zeros(int(SR), dtype=np.float32)      # 1 с «своей» вставки
    long_theirs = np.zeros(int(4 * SR), dtype=np.float32)  # 4 с «чужого»
    marker = LiveVoice(embed, lambda s: [(1.0, short_mine), (4.0, long_theirs)], [mine, theirs])
    mark = marker.mark(x)
    assert mark is not None and mark["speech"] == 4.0
    assert seen[-1] is long_theirs, "эмбеддится доминирующая дорожка"


def test_zero_embedding_is_rejected():
    marker, _ = _marker([1.0])
    marker.embed = lambda samples: np.zeros(8, dtype=np.float32)
    assert marker.mark(np.zeros(int(3 * SR), dtype=np.float32)) is None


def test_threshold_is_measured_value():
    """Страж от тихого изменения: порог и минимум речи равны замеру poc/livespk
    (чистая речь: свои 0.50–0.75, чужие ≤ 0.23; порог 0.40 — середина разрыва)."""
    assert THRESHOLD == 0.40
    assert MIN_SPEECH_SEC == 1.5
    assert SELF_NAME == "Я"


def test_load_without_self_person_returns_none(tmp_path):
    assert livevoice.load(tmp_path) is None


def _patch_models(monkeypatch):
    monkeypatch.setattr(livevoice, "_cpu_embedder", lambda: (lambda samples: np.zeros(8)))
    monkeypatch.setattr(livevoice, "_cpu_speech_tracks",
                        lambda: (lambda samples: [(3.0, samples)]))


def test_self_lookup_is_case_insensitive(tmp_path, monkeypatch):
    """В базе «я» с маленькой (заведена вручную до этапа 5) — маркер строится."""
    from mlaud_worker.voices import VoiceStore

    _patch_models(monkeypatch)
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
    from mlaud_worker.voices import VoiceStore

    upper = np.zeros(8, dtype=np.float32)
    upper[0] = 1.0
    lower = np.zeros(8, dtype=np.float32)
    lower[1] = 1.0
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        for order in ("lower-first", "upper-first"):   # не кириллицей: APFS не чувствует регистр
            store = VoiceStore(Path(d) / order)
            by_name = {"я": lower, "Я": upper}
            names = ("я", "Я") if order == "lower-first" else ("Я", "я")
            for n in names:
                store.add(n, by_name[n], source_file="old.m4a", label="S", speech_sec=30.0)
            refs = livevoice.self_refs(store)
            assert len(refs) == 1 and np.array_equal(refs[0], upper), \
                "точное «Я» старше регистра-двойника"
    with tempfile.TemporaryDirectory() as d:
        store = VoiceStore(Path(d) / "only")
        store.add("я", lower, source_file="old.m4a", label="S", speech_sec=30.0)
        assert len(livevoice.self_refs(store)) == 1, "одиночная «я» находится"
        store.add("Артём А", lower, source_file="x.m4a", label="S", speech_sec=30.0)
        assert livevoice.self_refs(VoiceStore(Path(d) / "empty")) == []


def test_best_of_refs_wins():
    """Счёт — лучший косинус по образцам: режимы голоса одного человека
    различаются, фразе достаточно совпасть с одним из образцов."""
    refs = [np.zeros(8, dtype=np.float32) for _ in range(2)]
    refs[0][0] = 1.0                                   # «начитка»
    refs[1][1] = 1.0                                   # «разговор»
    spoken = np.zeros(8, dtype=np.float32)
    spoken[1] = 1.0                                    # совпал разговорный
    tracks = lambda samples: [(3.0, samples)]
    marker = LiveVoice(lambda samples: spoken, tracks, refs)
    assert marker.mark(np.zeros(int(3 * SR), dtype=np.float32)) == \
        {"self": True, "score": 1.0, "speech": 3.0}


def test_load_with_self_person_builds_marker(tmp_path, monkeypatch):
    """Маркер из базы: персоны нет — None; есть «Я» — маркер (эмуляция эмбеддера:
    torch живёт в venv распознавателя, в тестовом — подмена)."""
    from mlaud_worker.voices import VoiceStore

    _patch_models(monkeypatch)
    vec = np.zeros(8, dtype=np.float32)
    vec[0] = 1.0
    store = VoiceStore(tmp_path)
    store.add("Кто-то", vec, source_file="x.m4a", label="SPEAKER_00", speech_sec=30.0)
    assert livevoice.load(tmp_path) is None
    store.add("Я", vec, source_file="ref.wav", label="SPEAKER_00", speech_sec=30.0,
              channel="reference")
    marker = livevoice.load(tmp_path)
    assert marker is not None
    assert marker.mark(np.zeros(int(3 * SR), dtype=np.float32)) is None  # нулевой эмбеддинг


def _model_available() -> bool:
    try:
        import pyannote.audio  # noqa: F401
        import soundfile  # noqa: F401
    except ImportError:
        return False
    return EVAL_DIR.exists() and (EVAL_DIR / "short_clips.md").exists()


@pytest.mark.skipif(not _model_available(), reason="нет pyannote/данных замера (~/ASR/spkid-eval)")
def test_s4_table_reproduced():
    """Полная переоценка — отдельный прогон poc/livespk/eval.py; здесь лишь страж:
    порог в коде равен порогу замера живых окон (0.40)."""
    assert THRESHOLD == 0.40
