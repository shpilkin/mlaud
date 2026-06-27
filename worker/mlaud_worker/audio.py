"""Декодирование аудио без внешнего ffmpeg: afconvert (macOS) + soundfile + soxr-ресемплинг.

Ключевой урок PoC (ADR-014): afconvert -r НЕ ресемплит надёжно, и предполагать частоту нельзя.
Поэтому декодируем в PCM как есть, читаем ФАКТИЧЕСКУЮ частоту и ресемплим до 16 кГц через soxr.
"""

import os
import subprocess
import tempfile

import numpy as np
import soundfile as sf

TARGET_SR = 16000


class AudioDecodeError(RuntimeError):
    pass


def _afconvert_to_wav(src_path: str, dst_path: str) -> None:
    """Декодировать любой поддерживаемый macOS формат (m4a/aac/mp3/wav) в PCM WAV (mono)."""
    try:
        subprocess.run(
            ["afconvert", str(src_path), "-d", "LEI16", "-f", "WAVE", "-c", "1", dst_path],
            check=True,
            capture_output=True,
        )
    except FileNotFoundError as e:  # afconvert отсутствует (не macOS)
        raise AudioDecodeError("afconvert not found (macOS only)") from e
    except subprocess.CalledProcessError as e:
        raise AudioDecodeError(
            f"afconvert failed for {src_path}: {e.stderr.decode('utf-8', 'ignore')[:200]}"
        ) from e


def load_audio(path: str, sr: int = TARGET_SR) -> np.ndarray:
    """Вернуть 16 кГц mono float32 numpy-массив. ffmpeg не используется.

    Замена для gigaam_mlx.transcribe.load_audio.
    """
    tmp = tempfile.mktemp(suffix=".wav")
    try:
        _afconvert_to_wav(path, tmp)
        audio, src_sr = sf.read(tmp, dtype="float32")
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

    if audio.ndim > 1:  # на всякий случай, хотя afconvert -c 1 даёт mono
        audio = audio.mean(axis=1)

    if src_sr != sr:
        import soxr

        audio = soxr.resample(audio, src_sr, sr)

    return np.ascontiguousarray(audio, dtype=np.float32)
