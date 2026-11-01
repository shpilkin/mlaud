"""HF-кэш как источник правды: модели скачаны — загрузка идёт с диска, без сети.

huggingface_hub 0.25 при живом кэше всё равно делает сетевой запрос к
huggingface.co и на рваном TLS (SSLEOFError) падает MaxRetryError'ом вместо
того чтобы взять локальный снапшот — 2026-10-12 полностью закэшированный
speaker-diarization-3.1 не загрузился, файл уехал в Failed (worker.log:2617).
HF_HUB_OFFLINE=1 переводит hub на локальный кэш: воспроизведено с мёртвой
сетью — пайплайн грузится и считает. Обновление кэша (новые ревизии моделей)
при этом невозможно; скачать заново — стереть кэш или пустить процесс с
HF_HUB_OFFLINE=0.
"""

import os
from pathlib import Path

from .config import read_dotenv

# Модели pyannote: пайплайн диаризации и его субмодели (diarize.PIPELINE),
# сегментация и wespeaker живой пометки (livevoice.SEG_MODEL, livevoice.MODEL).
# Списками, а не импортом констант: вызов идёт из __init__ пакета и не должен
# тянуть pyannote и mlx. Страж синхронности — test_hfcache.
REPOS = [
    "pyannote/speaker-diarization-3.1",
    "pyannote/segmentation-3.0",
    "pyannote/wespeaker-voxceleb-resnet34-LM",
]

# Веса распознавателя по типу модели, как gigaam_mlx.REPOS. Обязателен только
# выбранный: у работающего на rnnt ctc не скачан, и офлайн заблокировал бы его
# докачку при смене модели в настройках.
GIGAAM_REPOS = {
    "ctc": "aystream/GigaAM-v3-e2e-ctc-mlx",
    "rnnt": "aystream/GigaAM-v3-e2e-rnnt-mlx",
}


def _cache_dir() -> Path:
    """Разрешение каталога кэша как в huggingface_hub.constants, без его импорта."""
    if os.environ.get("HF_HUB_CACHE"):
        return Path(os.environ["HF_HUB_CACHE"])
    if os.environ.get("HF_HOME"):
        return Path(os.environ["HF_HOME"]) / "hub"
    return Path.home() / ".cache" / "huggingface" / "hub"


def _cached(cache: Path, repo: str) -> bool:
    """Репозиторий разрешим офлайн: refs/main ведёт на непустой снапшот."""
    root = cache / ("models--" + repo.replace("/", "--"))
    ref = root / "refs" / "main"
    if not ref.is_file():
        return False
    snapshot = root / "snapshots" / ref.read_text(encoding="utf-8").strip()
    return snapshot.is_dir() and any(snapshot.iterdir())


def _model_types() -> set:
    """Модели, которые может загрузить процесс: MLAUD_MODEL, а без него — из worker/.env
    (load_dotenv в __main__ идёт после импорта пакета) и rnnt (dictate .env не читает)."""
    if os.environ.get("MLAUD_MODEL"):
        return {os.environ["MLAUD_MODEL"]}
    return {read_dotenv().get("MLAUD_MODEL") or "rnnt", "rnnt"}


def _required() -> list:
    """pyannote и gigaam возможных моделей; неизвестный тип не валит импорт пакета."""
    return REPOS + sorted(GIGAAM_REPOS[m] for m in _model_types() if m in GIGAAM_REPOS)


def prefer_cache() -> bool:
    """Всё из `_required()` в кэше → HF_HUB_OFFLINE=1 и True; кэш неполон → сеть остаётся.

    Явно заданное значение переменной не перекрывается — это способ пользователя
    управлять режимом (0 — принудительно сеть, 1 — принудительно кэш).
    Флаг читается при импорте huggingface_hub, поэтому вызов обязан быть раньше
    любого его импорта — отсюда вызов из `mlaud_worker/__init__.py`.
    """
    if "HF_HUB_OFFLINE" in os.environ:
        return os.environ["HF_HUB_OFFLINE"] == "1"
    cache = _cache_dir()
    if all(_cached(cache, repo) for repo in _required()):
        os.environ["HF_HUB_OFFLINE"] = "1"
        return True
    return False
