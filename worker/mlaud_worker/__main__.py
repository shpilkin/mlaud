"""Запуск пакетной обработки inbox: python -m mlaud_worker

Конфиг — из переменных окружения (или дефолтные пути). Telegram включается, если задан токен.
"""

import os
import sys
from pathlib import Path

from .config import Config
from .pipeline import process_inbox
from .telegram import TelegramNotifier


def load_dotenv() -> None:
    """Минимальный загрузчик worker/.env (без зависимости python-dotenv).

    Заполняет os.environ только для ещё не заданных ключей.
    """
    env_path = Path(__file__).resolve().parent.parent / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip().strip('"').strip("'")
        if key and val and key not in os.environ:
            os.environ[key] = val


def build_config() -> Config:
    cfg = Config.default()
    if os.environ.get("MLAUD_INBOX"):
        cfg.inbox = os.environ["MLAUD_INBOX"]
    if os.environ.get("MLAUD_OUTPUT"):
        cfg.output = os.environ["MLAUD_OUTPUT"]
    if os.environ.get("MLAUD_PROCESSED"):
        cfg.processed = os.environ["MLAUD_PROCESSED"]
    if os.environ.get("MLAUD_FAILED"):
        cfg.failed = os.environ["MLAUD_FAILED"]
    if os.environ.get("MLAUD_SERVICE"):
        cfg.service = os.environ["MLAUD_SERVICE"]
    if os.environ.get("MLAUD_MODEL"):
        cfg.model_type = os.environ["MLAUD_MODEL"]
    if os.environ.get("MLAUD_DIARIZE"):
        cfg.diarize = os.environ["MLAUD_DIARIZE"].strip().lower() in ("1", "true", "yes", "on")
    if os.environ.get("MLAUD_HF_TOKEN"):
        cfg.hf_token = os.environ["MLAUD_HF_TOKEN"]
    if os.environ.get("MLAUD_DIARIZE_DEVICE"):
        cfg.diarize_device = os.environ["MLAUD_DIARIZE_DEVICE"]
    if os.environ.get("MLAUD_NUM_SPEAKERS"):
        try:
            cfg.num_speakers = int(os.environ["MLAUD_NUM_SPEAKERS"])
        except ValueError:
            cfg.num_speakers = 0
    cfg.__post_init__()
    return cfg


def build_notifier():
    token = os.environ.get("MLAUD_TG_TOKEN")
    chat = os.environ.get("MLAUD_TG_CHAT_ID")
    if token and chat:
        return TelegramNotifier(token, chat)
    return None


def main() -> int:
    load_dotenv()
    cfg = build_config()
    notifier = build_notifier()
    result = process_inbox(cfg, notifier=notifier)
    for r in result["processed"]:
        print(f"OK   {r['source']} -> {r['txt']} ({r['segments']} segments)")
    for e in result["errors"]:
        print(f"FAIL {e['source']}: {e['error']}", file=sys.stderr)
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
