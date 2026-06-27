"""Общие фикстуры pytest для worker'а."""

import os
import sys
from pathlib import Path

import pytest
import soundfile as sf

# Сделать пакет mlaud_worker импортируемым (worker/ на пути).
sys.path.insert(0, os.path.dirname(__file__))

REAL_M4A = Path("/Users/<user>/my_projects/mlaud/test data/Пример записи.m4a")


@pytest.fixture(scope="session")
def real_m4a() -> Path:
    if not REAL_M4A.exists():
        pytest.skip(f"тестовый файл отсутствует: {REAL_M4A}")
    return REAL_M4A


@pytest.fixture(scope="session")
def transcriber():
    from mlaud_worker.transcribe import Transcriber

    return Transcriber(model_type="rnnt")


@pytest.fixture(scope="session")
def short_clip(tmp_path_factory, real_m4a) -> Path:
    """Короткий (~25 c) клип из реальной записи в 16 кГц wav — для быстрых тестов конвейера."""
    from mlaud_worker.audio import load_audio, TARGET_SR

    audio = load_audio(str(real_m4a))
    clip = audio[: 25 * TARGET_SR]
    out = tmp_path_factory.mktemp("clip") / "2026-06-21_10-00-00.wav"
    sf.write(str(out), clip, TARGET_SR)
    return out
