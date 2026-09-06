"""Сдача артефакта роутеру: id по содержимому, время записи, сайдкар и папка обмена.

Главное, что здесь проверяется, — что worker остаётся тем, чем был: сбой на стороне
роутера не должен ронять транскрипцию, а имя файла не должно определять ни id встречи,
ни (пока в аудио есть метаданные) время записи.
"""

import json
import os
import struct
from datetime import UTC, datetime, timedelta
from pathlib import Path

from mlaud_worker import artifact


def _mvhd_m4a(path: Path, created: datetime, duration_sec: int, timescale: int = 1000):
    """Минимальный m4a: ftyp + moov/mvhd с нужными creation_time и duration."""
    secs = int((created - datetime(1904, 1, 1, tzinfo=UTC)).total_seconds())
    body = struct.pack(">B3s", 0, b"\0\0\0")  # version 0 + flags
    body += struct.pack(">IIII", secs, secs, timescale, duration_sec * timescale)
    body += b"\0" * 80  # хвост mvhd, который мы не читаем
    mvhd = struct.pack(">I4s", 8 + len(body), b"mvhd") + body
    moov = struct.pack(">I4s", 8 + len(mvhd), b"moov") + mvhd
    ftyp = struct.pack(">I4s", 16, b"ftyp") + b"M4A \0\0\0\0"
    path.write_bytes(ftyp + moov)
    return path


# --- id встречи ---


def test_meeting_id_follows_content_not_name(tmp_path):
    a = tmp_path / "New Recording 20.m4a"
    a.write_bytes(b"one-and-the-same-audio")
    first = artifact.meeting_id(a)

    renamed = tmp_path / "Планёрка.m4a"
    a.rename(renamed)
    assert artifact.meeting_id(renamed) == first  # переименование — та же встреча

    other = tmp_path / "other.m4a"
    other.write_bytes(b"another recording")
    assert artifact.meeting_id(other) != first
    assert len(first) == 16


# --- время начала записи ---


def test_started_at_prefers_audio_metadata(tmp_path):
    created = datetime(2026, 8, 16, 11, 30, 5, tzinfo=UTC)
    path = _mvhd_m4a(tmp_path / "New Recording 20.m4a", created, duration_sec=2820)
    # mtime уводим далеко в сторону: метаданные должны победить.
    old = (datetime.now(UTC) - timedelta(days=3)).timestamp()
    os.utime(path, (old, old))

    when, source = artifact.started_at(path)
    assert source == "audio-metadata"
    assert when == created
    assert artifact.read_mp4_meta(path)["duration_sec"] == 2820


def test_started_at_falls_back_to_a_timestamp_in_the_name(tmp_path):
    path = tmp_path / "2026-08-16_14-30-05.wav"  # не mp4 — метаданных нет
    path.write_bytes(b"RIFF....WAVEfmt ")
    when, source = artifact.started_at(path)
    assert source == "filename"
    assert (when.year, when.month, when.day, when.hour, when.minute) == (2026, 8, 16, 14, 30)

    # Формат, который реально лежит в архиве.
    other = tmp_path / "31 Dec 2025 at 20:55:55.m4a"
    other.write_bytes(b"not an mp4")
    when2, source2 = artifact.started_at(other)
    assert source2 == "filename"
    assert (when2.day, when2.month, when2.hour, when2.second) == (31, 12, 20, 55)


def test_started_at_falls_back_to_mtime_minus_duration(tmp_path):
    path = tmp_path / "New Recording 20.wav"  # ни метаданных, ни метки в имени
    path.write_bytes(b"RIFF")
    stamp = datetime(2026, 8, 16, 18, 0, tzinfo=UTC).timestamp()
    os.utime(path, (stamp, stamp))
    when, source = artifact.started_at(path, duration_sec=1800)
    assert source == "mtime-duration"
    assert when == datetime(2026, 8, 16, 17, 30, tzinfo=UTC)

    when2, source2 = artifact.started_at(path)  # длительность неизвестна
    assert source2 == "mtime"
    assert when2 == datetime(2026, 8, 16, 18, 0, tzinfo=UTC)


def test_read_mp4_meta_is_quiet_on_anything_else(tmp_path):
    junk = tmp_path / "junk.m4a"
    junk.write_bytes(b"\x00\x00\x00\x08free" + b"\xff" * 20)
    assert artifact.read_mp4_meta(junk) == {}
    assert artifact.read_mp4_meta(tmp_path / "missing.m4a") == {}


def test_real_recording_metadata(real_m4a):
    """На настоящей записи из архива метаданные читаются и выглядят осмысленно."""
    meta = artifact.read_mp4_meta(real_m4a)
    assert meta.get("duration_sec", 0) > 0
    assert 2000 < meta["created_at"].year < 2100


# --- сайдкар и папка обмена ---


def _payload(tmp_path, inbox=None):
    audio = _mvhd_m4a(tmp_path / "rec.m4a", datetime(2026, 8, 16, 11, 30, tzinfo=UTC), 2820)
    out = tmp_path / "ASROutput" / "2026-08"
    out.mkdir(parents=True)
    txt, srt = out / "rec.txt", out / "rec.srt"
    txt.write_text("расшифровка", encoding="utf-8")
    srt.write_text("1", encoding="utf-8")
    return artifact.build_payload(
        audio_path=audio, txt_path=txt, srt_path=srt, asr_root=tmp_path
    ), txt


def test_payload_paths_are_relative_to_the_archive_root(tmp_path):
    payload, _ = _payload(tmp_path)
    assert payload["transcript_path"] == "ASROutput/2026-08/rec.txt"
    assert payload["srt_path"] == "ASROutput/2026-08/rec.srt"
    assert payload["audio_path"] == "rec.m4a"
    assert payload["asr_root"] == str(tmp_path)
    assert payload["duration_sec"] == 2820
    assert payload["started_at_source"] == "audio-metadata"
    assert payload["source"] == "mlaud"
    # Проектов и уверенности здесь нет и не будет — их определяет роутер.
    assert "projects" not in payload and "confidence" not in payload


def test_sidecar_lands_next_to_the_transcript(tmp_path):
    payload, txt = _payload(tmp_path)
    path = artifact.write_sidecar(txt, payload)
    assert path == txt.with_suffix(".meta.json")
    assert json.loads(path.read_text(encoding="utf-8"))["meeting_id"] == payload["meeting_id"]


def test_handoff_writes_one_json_named_by_meeting_id(tmp_path):
    payload, _ = _payload(tmp_path)
    inbox = tmp_path / "artifacts_inbox"
    path = artifact.handoff(inbox, payload)
    assert path.name == f"{payload['meeting_id']}.json"
    # Атомарность: временных файлов после записи не остаётся.
    assert [p.name for p in inbox.iterdir()] == [path.name]
    assert json.loads(path.read_text(encoding="utf-8")) == payload
    # Обмен выключен — ничего не пишем и не падаем.
    assert artifact.handoff(None, payload) is None


def test_file_duration_beats_the_last_segment(tmp_path):
    """Расшифровка обрывается на последней реплике; длительность берём из файла."""
    audio = _mvhd_m4a(tmp_path / "rec.m4a", datetime(2026, 8, 16, 11, 30, tzinfo=UTC), 828)
    txt = tmp_path / "rec.txt"
    txt.write_text("текст", encoding="utf-8")
    payload = artifact.build_payload(
        audio_path=audio, txt_path=txt, srt_path=None, asr_root=tmp_path,
        duration_sec=1400,  # «конец последнего сегмента» врёт в большую сторону
    )
    assert payload["duration_sec"] == 828


# --- запись звонка Суфлёра (этап 3) ---


def test_build_payload_started_at_override_marks_source_sidecar(tmp_path):
    audio = _mvhd_m4a(tmp_path / "rec.m4a", datetime(2026, 8, 16, 11, 30, tzinfo=UTC), 2820)
    txt = tmp_path / "rec.txt"
    txt.write_text("текст", encoding="utf-8")
    call_started = datetime(2026, 9, 4, 15, 30, 5).astimezone()
    payload = artifact.build_payload(
        audio_path=audio, txt_path=txt, srt_path=None, asr_root=tmp_path,
        started_at=call_started,
    )
    assert payload["started_at_source"] == "sidecar"
    assert payload["started_at"] == call_started.isoformat()
    assert payload["started_at"].startswith("2026-09-04T15:30:05")
    assert payload["duration_sec"] == 2820             # длительность по-прежнему из файла
    assert list(payload)[:3] == ["meeting_id", "started_at", "started_at_source"]


def test_prompter_block_relative_path_and_nulls(tmp_path):
    outcome = tmp_path / "ASROutput" / "2026-09" / "2026-09-04_15-30-05.prompter.md"
    block = artifact.prompter_block(
        call_id="2026-09-04_15-30-05", brief=None, goal=None,
        outcome_path=outcome, asr_root=tmp_path,
    )
    assert block == {
        "call_id": "2026-09-04_15-30-05", "brief": None, "goal": None,
        "outcome_path": "ASROutput/2026-09/2026-09-04_15-30-05.prompter.md",
    }
    assert list(block) == ["call_id", "brief", "goal", "outcome_path"]
    none = artifact.prompter_block(call_id="x", brief="бриф", goal=None,
                                   outcome_path=None, asr_root=tmp_path)
    assert none["outcome_path"] is None and none["brief"] == "бриф"


def test_build_payload_adds_prompter_only_when_given(tmp_path):
    payload, _ = _payload(tmp_path)
    assert "prompter" not in payload
    block = {"call_id": "c", "brief": None, "goal": None, "outcome_path": None}
    audio = _mvhd_m4a(tmp_path / "rec2.m4a", datetime(2026, 8, 16, 11, 30, tzinfo=UTC), 10)
    txt = tmp_path / "rec2.txt"
    txt.write_text("т", encoding="utf-8")
    with_block = artifact.build_payload(
        audio_path=audio, txt_path=txt, srt_path=None, asr_root=tmp_path, prompter=block,
    )
    assert with_block["prompter"] == block
    assert list(with_block)[-1] == "prompter"
