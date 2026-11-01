"""Тесты офлайн-политики HF-кэша: полный кэш → HF_HUB_OFFLINE, неполный → сеть.

Контекст: huggingface_hub 0.25 при живом кэше всё равно ходит в сеть за
ревизией и на рваном TLS падает вместо кэша (worker.log 2026-10-12)."""

import os
import sys
import types

import pytest

from mlaud_worker import hfcache
from mlaud_worker.hfcache import GIGAAM_REPOS, REPOS, prefer_cache

# Всё, что нужно процессу при модели по умолчанию.
FULL = REPOS + [GIGAAM_REPOS["rnnt"]]


def _repo_dir(root, repo):
    """Имя каталога репозитория в кэше hub (префикс models-- обязателен)."""
    return root / ("models--" + repo.replace("/", "--"))


def _fill_cache(root, repos=FULL):
    for repo in repos:
        base = _repo_dir(root, repo)
        (base / "refs").mkdir(parents=True)
        (base / "refs" / "main").write_text("deadbeef", encoding="utf-8")
        snap = base / "snapshots" / "deadbeef"
        snap.mkdir(parents=True)
        (snap / "config.yaml").write_text("{}", encoding="utf-8")


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch, tmp_path):
    """Кэш и переменные — каждый тест в своём каталоге; состояние машины не влияет."""
    monkeypatch.delenv("HF_HUB_OFFLINE", raising=False)
    monkeypatch.delenv("HF_HUB_CACHE", raising=False)
    monkeypatch.delenv("MLAUD_MODEL", raising=False)
    monkeypatch.setattr(hfcache, "read_dotenv", lambda: {})
    monkeypatch.setenv("HF_HOME", str(tmp_path / "empty-hf"))
    yield
    os.environ.pop("HF_HUB_OFFLINE", None)


def test_full_cache_switches_to_offline(tmp_path, monkeypatch):
    _fill_cache(tmp_path / "hf" / "hub")
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    assert prefer_cache() is True
    assert os.environ["HF_HUB_OFFLINE"] == "1"


def test_missing_repo_keeps_network(tmp_path, monkeypatch):
    _fill_cache(tmp_path / "hf" / "hub")
    (_repo_dir(tmp_path / "hf" / "hub", REPOS[0]) / "refs" / "main").unlink()
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    assert prefer_cache() is False
    assert "HF_HUB_OFFLINE" not in os.environ


def test_ref_without_snapshot_keeps_network(tmp_path, monkeypatch):
    """refs/main есть, снапшота нет — офлайн загрузка всё равно не разрешится."""
    _fill_cache(tmp_path / "hf" / "hub")
    base = _repo_dir(tmp_path / "hf" / "hub", REPOS[1])
    for f in (base / "snapshots" / "deadbeef").iterdir():
        f.unlink()
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    assert prefer_cache() is False


def test_explicit_env_is_respected(monkeypatch):
    monkeypatch.setenv("HF_HUB_OFFLINE", "0")
    assert prefer_cache() is False
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    assert prefer_cache() is True


def test_hf_hub_cache_dir_wins(tmp_path, monkeypatch):
    """HF_HUB_CACHE точнее HF_HOME — кэш ищется там (как в huggingface_hub)."""
    _fill_cache(tmp_path / "direct")
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "direct"))
    assert prefer_cache() is True


def test_selected_model_missing_keeps_network(tmp_path, monkeypatch):
    """pyannote и rnnt в кэше, выбран ctc, а его нет: офлайн заблокировал бы докачку."""
    _fill_cache(tmp_path / "hf" / "hub")
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    monkeypatch.setenv("MLAUD_MODEL", "ctc")
    assert prefer_cache() is False
    assert "HF_HUB_OFFLINE" not in os.environ


def test_selected_model_cached_switches_to_offline(tmp_path, monkeypatch):
    """Выбран ctc и он в кэше — rnnt процессу не нужен."""
    _fill_cache(tmp_path / "hf" / "hub", REPOS + [GIGAAM_REPOS["ctc"]])
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    monkeypatch.setenv("MLAUD_MODEL", "ctc")
    assert prefer_cache() is True


def test_dotenv_model_and_default_are_required(tmp_path, monkeypatch):
    """Без MLAUD_MODEL в окружении __main__ возьмёт модель из worker/.env, а dictate — rnnt."""
    _fill_cache(tmp_path / "hf" / "hub", REPOS + [GIGAAM_REPOS["ctc"]])
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    monkeypatch.setattr(hfcache, "read_dotenv", lambda: {"MLAUD_MODEL": "ctc"})
    assert prefer_cache() is False
    _fill_cache(tmp_path / "hf" / "hub", [GIGAAM_REPOS["rnnt"]])
    assert prefer_cache() is True


def test_unknown_model_does_not_break_import(tmp_path, monkeypatch):
    """Неизвестный тип упадёт в load_model при любом режиме; prefer_cache зовётся из
    __init__ пакета и падать не должен."""
    _fill_cache(tmp_path / "hf" / "hub", REPOS)
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    monkeypatch.setenv("MLAUD_MODEL", "нет такой")
    assert prefer_cache() is True


def test_repos_cover_all_hf_models():
    """Страж синхронности: списки политики — модели diarize, livevoice и gigaam_mlx."""
    import gigaam_mlx

    from mlaud_worker import livevoice
    from mlaud_worker.diarize import Diarizer

    assert {Diarizer.PIPELINE, livevoice.MODEL, livevoice.SEG_MODEL} <= set(REPOS)
    assert GIGAAM_REPOS == gigaam_mlx.REPOS


def test_diarize_load_failure_is_human_readable(monkeypatch):
    """Сырой сетевой трейсбек (OSError-ветка requests) → RuntimeError с текстом;
    иначе в меню приложения прилетает MaxRetryError urllib3."""
    from mlaud_worker.diarize import Diarizer

    fake_pa = types.ModuleType("pyannote.audio")

    class Pipeline:
        @staticmethod
        def from_pretrained(*args, **kwargs):
            raise ConnectionError(
                "MaxRetryError(... huggingface.co ...)")

    fake_pa.Pipeline = Pipeline
    fake_torch = types.ModuleType("torch")
    fake_torch.device = lambda name: name
    monkeypatch.setitem(sys.modules, "pyannote.audio", fake_pa)
    monkeypatch.setitem(sys.modules, "torch", fake_torch)

    with pytest.raises(RuntimeError, match="huggingface.co недоступен"):
        Diarizer(hf_token="t")._ensure_loaded()
