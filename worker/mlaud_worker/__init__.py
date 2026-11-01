"""MLaud worker: локальная транскрипция аудио (GigaAM-v3 MLX) для личного аналога Plaud."""

from .hfcache import prefer_cache

# До любых импортов huggingface_hub (флаг читается при его импорте): при полном
# кэше моделей загрузка идёт с диска и не зависит от рваного TLS до huggingface.co.
prefer_cache()

__all__ = [
    "audio", "transcribe", "output", "telegram", "pipeline", "config", "auth", "artifact",
]
