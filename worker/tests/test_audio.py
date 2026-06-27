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
