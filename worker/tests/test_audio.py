"""Тесты декодирования аудио — главный — защита от бага ресемплинга (ADR-014)."""

import numpy as np

from mlaud_worker.audio import load_audio, TARGET_SR


def test_decode_real_m4a_resamples_to_16k(real_m4a):
    """48-кГц m4a должен декодироваться в 16 кГц с ПРАВИЛЬНОЙ длительностью (~829 c).

    Регрессия на баг PoC: без ресемплинга длительность «вырастала» втрое (~2486 c).
    """
    audio = load_audio(str(real_m4a))
    duration = len(audio) / TARGET_SR
    assert 820 < duration < 838, f"ожидали ~829 c, получили {duration:.1f} c (баг ресемплинга?)"


def test_decode_returns_mono_float32_normalized(real_m4a):
    audio = load_audio(str(real_m4a))
    assert audio.ndim == 1
    assert audio.dtype == np.float32
    assert np.abs(audio).max() <= 1.0
    assert np.abs(audio).max() > 0.01  # не тишина


def test_decode_wav_passthrough(short_clip):
    """16-кГц wav должен оставаться 16 кГц (ресемплинг не ломает совпадающую частоту)."""
    audio = load_audio(str(short_clip))
    duration = len(audio) / TARGET_SR
    assert 24 < duration < 26


# --- запасной декодер ffmpeg (webm/mkv видеовстреч) ---------------------------------

import shutil
import subprocess

import pytest

from mlaud_worker import audio as audio_mod
from mlaud_worker.audio import AudioDecodeError


@pytest.fixture(scope="module")
def webm_meeting(tmp_path_factory, short_clip):
    """Как запись видеовстречи: VP8-видео + стерео Opus 48 кГц в webm."""
    exe = audio_mod._ffmpeg_exe()
    if exe is None:
        pytest.skip("ffmpeg недоступен")
    out = tmp_path_factory.mktemp("webm") / "Видеовстреча 2026-10-22_093844.webm"
    r = subprocess.run([exe, "-v", "error", "-y", "-i", str(short_clip),
                        "-f", "lavfi", "-i", "color=c=black:s=64x64:d=25", "-shortest",
                        "-ac", "2", "-ar", "48000", "-c:a", "libopus", "-c:v", "libvpx", str(out)],
                       capture_output=True)
    if r.returncode != 0:
        pytest.skip(f"этот ffmpeg не умеет кодировать webm: {r.stderr[-200:]!r}")
    return out


def test_decode_webm_with_video_via_ffmpeg(webm_meeting):
    a = load_audio(str(webm_meeting))
    assert a.ndim == 1 and a.dtype == np.float32
    assert 24 < len(a) / TARGET_SR < 26
    assert np.abs(a).max() > 0.01


def test_afconvert_first_ffmpeg_only_on_failure(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(audio_mod, "_afconvert_to_wav", lambda s, d: calls.append("af"))
    monkeypatch.setattr(audio_mod, "_ffmpeg_to_wav", lambda s, d: calls.append("ff"))
    audio_mod._decode_to_wav("x.m4a", str(tmp_path / "o.wav"))
    assert calls == ["af"]


def test_both_decoders_fail_reports_both(monkeypatch, tmp_path):
    def af(s, d):
        raise AudioDecodeError("afconvert failed: typ?")

    def ff(s, d):
        raise AudioDecodeError("ffmpeg failed: Invalid data")
    monkeypatch.setattr(audio_mod, "_afconvert_to_wav", af)
    monkeypatch.setattr(audio_mod, "_ffmpeg_to_wav", ff)
    with pytest.raises(AudioDecodeError, match="afconvert failed.*ffmpeg failed"):
        audio_mod._decode_to_wav("x.webm", str(tmp_path / "o.wav"))


def test_no_ffmpeg_is_decode_error(monkeypatch, tmp_path):
    monkeypatch.setattr(audio_mod, "_ffmpeg_exe", lambda: None)
    with pytest.raises(AudioDecodeError, match="ffmpeg not found"):
        audio_mod._ffmpeg_to_wav("x.webm", str(tmp_path / "o.wav"))


def test_junk_file_fails_cleanly(tmp_path):
    p = tmp_path / "junk.webm"
    p.write_bytes(b"not a media file" * 100)
    with pytest.raises(AudioDecodeError):
        load_audio(str(p))
