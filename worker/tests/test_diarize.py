"""Юнит-тесты диаризации: наложение спикеров на сегменты (без pyannote/torch)."""

from mlaud_worker.diarize import (
    relabel, assign_speakers, group_words_by_speaker, _overlap,
)
from mlaud_worker.output import build_txt, build_srt


TURNS = [
    {"start": 0.0, "end": 4.0, "speaker": "SPEAKER_01"},
    {"start": 4.0, "end": 8.0, "speaker": "SPEAKER_00"},
    {"start": 8.0, "end": 12.0, "speaker": "SPEAKER_01"},
]

SEGS = [
    {"start": 0.5, "end": 3.5, "text": "Первая реплика."},
    {"start": 4.2, "end": 7.5, "text": "Вторая реплика."},
    {"start": 8.1, "end": 11.0, "text": "Третья реплика."},
]


def test_overlap():
    assert _overlap(0, 5, 3, 8) == 2
    assert _overlap(0, 2, 5, 8) == 0
    assert _overlap(1, 4, 1, 4) == 3


def test_relabel_orders_by_first_appearance():
    mapping = relabel(TURNS)
    # SPEAKER_01 появляется первым по времени → «Спикер 1»
    assert mapping["SPEAKER_01"] == "Спикер 1"
    assert mapping["SPEAKER_00"] == "Спикер 2"


def test_assign_speakers_by_max_overlap():
    out = assign_speakers(SEGS, TURNS)
    assert out[0]["speaker"] == "Спикер 1"
    assert out[1]["speaker"] == "Спикер 2"
    assert out[2]["speaker"] == "Спикер 1"
    # исходные сегменты не мутированы
    assert "speaker" not in SEGS[0]


def test_assign_speakers_no_overlap_leaves_unlabeled():
    seg = [{"start": 100.0, "end": 105.0, "text": "вне диаризации"}]
    out = assign_speakers(seg, TURNS)
    assert "speaker" not in out[0]


def test_assign_speakers_empty_turns():
    out = assign_speakers(SEGS, [])
    assert all("speaker" not in s for s in out)


def test_output_renders_speaker_prefix():
    out = assign_speakers(SEGS, TURNS)
    txt = build_txt(out)
    assert "[00:00:00] Спикер 1: Первая реплика." in txt
    assert "[00:00:04] Спикер 2: Вторая реплика." in txt
    srt = build_srt(out)
    assert "Спикер 1: Первая реплика." in srt


def test_group_words_splits_at_speaker_change():
    """Слова склеиваются в реплики, граница проходит по смене спикера."""
    words = [
        {"start": 0.0, "end": 0.5, "text": "привет"},
        {"start": 0.5, "end": 1.0, "text": "как"},
        {"start": 5.0, "end": 5.5, "text": "нормально"},   # другой спикер
        {"start": 5.5, "end": 6.0, "text": "спасибо"},
    ]
    turns = [
        {"start": 0.0, "end": 2.0, "speaker": "SPEAKER_00"},
        {"start": 4.5, "end": 7.0, "speaker": "SPEAKER_01"},
    ]
    segs = group_words_by_speaker(words, turns)
    assert len(segs) == 2
    assert segs[0]["speaker"] == "Спикер 1"
    assert segs[0]["text"] == "привет как"
    assert segs[0]["start"] == 0.0 and segs[0]["end"] == 1.0
    assert segs[1]["speaker"] == "Спикер 2"
    assert segs[1]["text"] == "нормально спасибо"
    assert segs[1]["start"] == 5.0 and segs[1]["end"] == 6.0


def test_group_words_consecutive_same_speaker_merge():
    words = [
        {"start": 0.0, "end": 0.5, "text": "раз"},
        {"start": 0.5, "end": 1.0, "text": "два"},
        {"start": 1.0, "end": 1.5, "text": "три"},
    ]
    turns = [{"start": 0.0, "end": 2.0, "speaker": "SPEAKER_00"}]
    segs = group_words_by_speaker(words, turns)
    assert len(segs) == 1
    assert segs[0]["text"] == "раз два три"


def test_group_words_no_turns_single_unlabeled_segment():
    words = [
        {"start": 0.0, "end": 0.5, "text": "раз"},
        {"start": 0.5, "end": 1.0, "text": "два"},
    ]
    segs = group_words_by_speaker(words, [])
    assert len(segs) == 1
    assert "speaker" not in segs[0]
    assert segs[0]["text"] == "раз два"


def test_output_without_speaker_unchanged():
    # сегменты без диаризации форматируются как раньше (без префикса)
    txt = build_txt(SEGS)
    assert txt.startswith("[00:00:00] Первая реплика.")
