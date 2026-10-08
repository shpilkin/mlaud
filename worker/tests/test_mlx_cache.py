"""Предел кэша MLX ставится обоими загрузчиками модели: пакетным и резидентным."""

import pytest

mx = pytest.importorskip("mlx.core")
gigaam_mlx = pytest.importorskip("gigaam_mlx")

from mlaud_worker import dictate, mlx_cache  # noqa: E402
from mlaud_worker.transcribe import Transcriber  # noqa: E402

SENTINEL = 12345


def _current_limit() -> int:
    """set_cache_limit возвращает прежнее значение — читаем и возвращаем как было."""
    value = mx.set_cache_limit(SENTINEL)
    mx.set_cache_limit(value)
    return value


@pytest.fixture
def fake_model(monkeypatch):
    """Загрузка весов подменена: проверяется только порядок «предел → модель»."""
    seen = []

    def load_model(model_type="rnnt"):
        seen.append(_current_limit())
        return object(), object()

    monkeypatch.setattr(gigaam_mlx, "load_model", load_model)
    mx.set_cache_limit(SENTINEL)
    yield seen
    mx.set_cache_limit(SENTINEL)


def test_limit_cache_sets_one_gigabyte():
    mx.set_cache_limit(SENTINEL)
    mlx_cache.limit_cache()
    assert _current_limit() == mlx_cache.CACHE_LIMIT_BYTES == 1 << 30


def test_transcriber_limits_cache_before_loading(fake_model):
    Transcriber("rnnt")._ensure_loaded()
    assert fake_model == [mlx_cache.CACHE_LIMIT_BYTES]


def test_resident_decoder_limits_cache_before_loading(fake_model):
    dictate._build_decoder("rnnt")
    assert fake_model == [mlx_cache.CACHE_LIMIT_BYTES]
