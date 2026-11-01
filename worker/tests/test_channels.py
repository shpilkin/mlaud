"""Запись звонка Суфлёра: сайдкар каналов, разбор стерео по дорожкам, слияние реплик."""

import json
import subprocess
from datetime import datetime
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from mlaud_worker import channels as ch


def _sidecar(path: Path, **override) -> Path:
    raw = {"version": 1, "call_id": "2026-09-04_15-30-05",
           "channels": {"0": "Я", "1": "Собеседник"}}
    raw.update(override)
    path.write_text(json.dumps(raw, ensure_ascii=False), encoding="utf-8")
    return path


def _stereo_wav(path: Path, sr: int = 16000, seconds: float = 1.0) -> Path:
    """Левый канал — тон 440 Гц, правый — тишина."""
    t = np.arange(int(sr * seconds)) / sr
    left = (0.5 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
    right = np.zeros_like(left)
    sf.write(str(path), np.stack([left, right], axis=1), sr, subtype="PCM_16")
    return path


def _rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(x.astype(np.float64) ** 2)))


def test_read_sidecar_ok_and_rejects_bad(tmp_path):
    ok = ch.read_sidecar(_sidecar(tmp_path / "ok.channels.json"))
    assert ok == ch.ChannelsSidecar(version=1, call_id="2026-09-04_15-30-05",
                                    channels={"0": "Я", "1": "Собеседник"}, brief=None)
    # null и отсутствие brief — одно и то же
    assert ch.read_sidecar(_sidecar(tmp_path / "n.channels.json", brief=None)).brief is None
    assert ch.read_sidecar(_sidecar(tmp_path / "b.channels.json", brief="план")).brief == "план"

    with pytest.raises(ch.SidecarError):
        ch.read_sidecar(_sidecar(tmp_path / "no1.channels.json", channels={"0": "Я"}))
    with pytest.raises(ch.SidecarError):
        ch.read_sidecar(_sidecar(tmp_path / "v2.channels.json", version=2))
    with pytest.raises(ch.SidecarError):
        ch.read_sidecar(_sidecar(tmp_path / "num.channels.json", channels={"0": 1, "1": "x"}))
    with pytest.raises(ch.SidecarError):
        ch.read_sidecar(_sidecar(tmp_path / "id.channels.json", call_id=5))
    bad = tmp_path / "bad.channels.json"
    bad.write_text("{не json", encoding="utf-8")
    with pytest.raises(ch.SidecarError):
        ch.read_sidecar(bad)
    with pytest.raises(ch.SidecarError):
        ch.read_sidecar(tmp_path / "missing.channels.json")


def test_started_at_from_call_id():
    sc = ch.ChannelsSidecar(1, "2026-09-04_15-30-05", {"0": "Я", "1": "Собеседник"}, None)
    when = ch.started_at(sc)
    assert when == datetime(2026, 9, 4, 15, 30, 5).astimezone()
    assert when.tzinfo is not None
    junk = ch.ChannelsSidecar(1, "New Recording 20", {"0": "Я", "1": "Собеседник"}, None)
    assert ch.started_at(junk) is None


def test_find_sidecar_next_to_audio(tmp_path):
    audio = tmp_path / "2026-09-04_15-30-05.m4a"
    assert ch.sidecar_path(audio) == tmp_path / "2026-09-04_15-30-05.channels.json"
    assert ch.find_sidecar(audio) is None
    side = _sidecar(ch.sidecar_path(audio))
    assert ch.find_sidecar(audio) == side           # аудио может ещё не существовать


def test_load_channels_keeps_two_columns(tmp_path):
    wav = _stereo_wav(tmp_path / "stereo.wav", sr=48000)
    data = ch.load_channels(wav)
    assert data.dtype == np.float32 and data.ndim == 2 and data.shape[1] == 2
    assert abs(data.shape[0] - 16000) < 10                  # ресемплинг 48к → 16к
    assert _rms(data[:, 0]) > 0.1 and _rms(data[:, 1]) < 1e-4

    m4a = tmp_path / "stereo.m4a"
    subprocess.run(["afconvert", str(wav), "-f", "m4af", "-d", "aac", str(m4a)],
                   check=True, capture_output=True)
    data = ch.load_channels(m4a)
    assert data.shape[1] == 2
    assert _rms(data[:, 0]) > 0.1 and _rms(data[:, 1]) < 1e-4


def test_split_channels_writes_mono_wavs(tmp_path):
    wav = _stereo_wav(tmp_path / "stereo.wav")
    paths = ch.split_channels(wav, tmp_path / "work")
    assert [p.name for p in paths] == ["ch0.wav", "ch1.wav"]
    left, sr = sf.read(str(paths[0]), dtype="float32")
    right, _ = sf.read(str(paths[1]), dtype="float32")
    assert sr == 16000 and left.ndim == 1 and right.ndim == 1
    assert _rms(left) > 0.1 and _rms(right) < 1e-4


def test_split_channels_mono_raises(tmp_path):
    mono = tmp_path / "mono.wav"
    sf.write(str(mono), np.zeros(16000, dtype=np.float32), 16000, subtype="PCM_16")
    with pytest.raises(ch.SidecarError, match="моно"):
        ch.split_channels(mono, tmp_path / "work")


def test_merge_by_time_is_stable_across_channels():
    a = [{"start": 0.0, "end": 1.0, "text": "a0"}, {"start": 5.0, "end": 6.0, "text": "a5"}]
    b = [{"start": 0.0, "end": 1.0, "text": "b0"}, {"start": 2.0, "end": 3.0, "text": "b2"}]
    assert [s["text"] for s in ch.merge_by_time([a, b])] == ["a0", "b0", "b2", "a5"]


class _PerFileTranscriber:
    """Сегменты зависят от имени файла дорожки; одни и те же dict'ы отдаются каждый вызов."""

    def __init__(self):
        self.calls = []
        self.by_name = {
            "ch0.wav": [{"start": 0.0, "end": 1.0, "text": "привет"},
                        {"start": 4.0, "end": 5.0, "text": "да"}],
            "ch1.wav": [{"start": 0.0, "end": 1.5, "text": "здравствуйте"},
                        {"start": 2.0, "end": 3.0, "text": "как дела"}],
        }

    def transcribe(self, path):
        self.calls.append(Path(path).name)
        return list(self.by_name[Path(path).name])


def test_transcribe_channels_labels_and_merges(tmp_path):
    wav = _stereo_wav(tmp_path / "2026-09-04_15-30-05.wav")
    sidecar = ch.ChannelsSidecar(1, "2026-09-04_15-30-05", {"0": "Я", "1": "Иван"}, None)
    tr = _PerFileTranscriber()
    segs = ch.transcribe_channels(wav, sidecar, tr)
    assert tr.calls == ["ch0.wav", "ch1.wav"]
    assert [(s["speaker"], s["channel"], s["text"]) for s in segs] == [
        ("Я", 0, "привет"),              # равный start → сначала канал 0
        ("Иван", 1, "здравствуйте"),
        ("Иван", 1, "как дела"),
        ("Я", 0, "да"),
    ]
    assert [s["start"] for s in segs] == sorted(s["start"] for s in segs)
    # исходные сегменты транскрайбера не испорчены подписью другого канала
    assert "speaker" not in tr.by_name["ch0.wav"][0]


def test_transcribe_channels_needs_label_for_every_track(tmp_path):
    t = np.zeros(16000, dtype=np.float32)
    wav = tmp_path / "three.wav"
    sf.write(str(wav), np.stack([t, t, t], axis=1), 16000, subtype="PCM_16")
    sidecar = ch.ChannelsSidecar(1, "x", {"0": "Я", "1": "Собеседник"}, None)
    with pytest.raises(ch.SidecarError):
        ch.transcribe_channels(wav, sidecar, _PerFileTranscriber())


def _say(path: Path, text: str) -> np.ndarray:
    from mlaud_worker.audio import load_audio

    subprocess.run(["say", "-v", "Milena", "-o", str(path), text], check=True, capture_output=True)
    return load_audio(str(path))


def test_channels_real_model_end_to_end(tmp_path, transcriber):
    """Настоящая модель: две синтезированные фразы в L/R расходятся по подписям каналов."""
    left = _say(tmp_path / "left.aiff", "Сегодня мы обсуждаем бюджет на следующий квартал")
    right = _say(tmp_path / "right.aiff", "Пожалуйста, пришлите договор по электронной почте")
    n = max(left.size, right.size) + 8000
    stereo = np.zeros((n, 2), dtype=np.float32)
    stereo[: left.size, 0] = left
    stereo[8000: 8000 + right.size, 1] = right
    wav = tmp_path / "2026-09-04_15-30-05.wav"
    sf.write(str(wav), stereo, 16000, subtype="PCM_16")
    sidecar = ch.ChannelsSidecar(1, "2026-09-04_15-30-05", {"0": "Я", "1": "Собеседник"}, None)

    segs = ch.transcribe_channels(wav, sidecar, transcriber)
    me = " ".join(s["text"] for s in segs if s["speaker"] == "Я").lower()
    them = " ".join(s["text"] for s in segs if s["speaker"] == "Собеседник").lower()
    assert "бюджет" in me and "бюджет" not in them, (me, them)
    assert "договор" in them and "договор" not in me, (me, them)
