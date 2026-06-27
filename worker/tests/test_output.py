"""Юнит-тесты форматирования вывода (.txt/.srt) — без модели."""

from mlaud_worker.output import format_timestamp, build_txt, build_srt, write_outputs

SEGS = [
    {"start": 0.0, "end": 3.5, "text": "Привет, это первый сегмент."},
    {"start": 3.5, "end": 7.25, "text": "  Второй сегмент.  "},
    {"start": 7.25, "end": 9.0, "text": "   "},  # пустой → отбрасывается
]


def test_format_timestamp_srt_and_txt():
    assert format_timestamp(0.0, sep=",") == "00:00:00,000"
    assert format_timestamp(3661.5, sep=",") == "01:01:01,500"
    assert format_timestamp(3661.5, sep=".") == "01:01:01.500"


def test_format_timestamp_ms_rounding_no_overflow():
    # 0.9999 c -> 999 мс, без перескока в 1000
    assert format_timestamp(0.9999, sep=",") == "00:00:01,000"
    assert format_timestamp(1.4, sep=",") == "00:00:01,400"


def test_build_txt_skips_empty_and_strips():
    txt = build_txt(SEGS)
    lines = txt.strip().split("\n")
    assert len(lines) == 2
    assert lines[0] == "[00:00:00] Привет, это первый сегмент."
    assert lines[1] == "[00:00:03] Второй сегмент."


def test_build_srt_indexing_and_format():
    srt = build_srt(SEGS)
    assert "1\n00:00:00,000 --> 00:00:03,500\nПривет, это первый сегмент." in srt
    assert "2\n00:00:03,500 --> 00:00:07,250\nВторой сегмент." in srt
    assert "3\n" not in srt  # пустой сегмент пропущен


def test_write_outputs_creates_files(tmp_path):
    paths = write_outputs(SEGS, tmp_path / "2026-06-21", "rec1")
    assert paths["txt"].exists() and paths["srt"].exists()
    assert paths["txt"].read_text(encoding="utf-8").startswith("[00:00:00]")
    assert "-->" in paths["srt"].read_text(encoding="utf-8")
