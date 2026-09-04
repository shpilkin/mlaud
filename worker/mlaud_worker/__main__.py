"""Запуск пакетной обработки inbox: python -m mlaud_worker

Конфиг — из переменных окружения (или дефолтные пути). Telegram включается, если задан токен.
"""

import os
import sys
from pathlib import Path

from .config import Config
from .delivery_queue import MAX_ATTEMPTS
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


def _flag(key: str) -> bool:
    return os.environ.get(key, "").strip().lower() in ("1", "true", "yes", "on")


def _float_env(key: str, default: float) -> float:
    try:
        return float(os.environ[key])
    except (KeyError, ValueError):
        return default


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
    if os.environ.get("MLAUD_ROUTER_INBOX"):
        # Папка обмена с роутером (Niti). Не задана — сдача артефактов выключена, но
        # сайдкар рядом с транскриптом пишется всё равно: он полезен сам по себе.
        cfg.router_inbox = os.environ["MLAUD_ROUTER_INBOX"]
    if os.environ.get("MLAUD_NUM_SPEAKERS"):
        try:
            cfg.num_speakers = int(os.environ["MLAUD_NUM_SPEAKERS"])
        except ValueError:
            cfg.num_speakers = 0
    # Голос-ID поверх диаризации (Фаза 3).
    if os.environ.get("MLAUD_IDENTIFY"):
        cfg.identify = _flag("MLAUD_IDENTIFY")
    if os.environ.get("MLAUD_VOICES_DIR"):
        cfg.voices_dir = os.environ["MLAUD_VOICES_DIR"]
    cfg.identify_threshold = _float_env("MLAUD_IDENTIFY_THRESHOLD", cfg.identify_threshold)
    cfg.identify_min_speech = _float_env("MLAUD_IDENTIFY_MIN_SPEECH", cfg.identify_min_speech)
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
    delivery_failed = False
    # Досланные из очереди прошлых прогонов (сеть вернулась).
    for base in result.get("redelivered", []):
        print(f"RESEND {base}: недоставленный ранее транскрипт отправлен")
    for r in result["processed"]:
        delivery = r.get("delivery", "?")
        speakers = r.get("speakers") or {}
        tail = ""
        if speakers.get("status") == "written":
            tail = f" [к разметке: {speakers.get('pending', 0)}]"
        elif speakers.get("status"):
            tail = f" [сайдкар голосов: {speakers['status']}]"
        print(f"OK   {r['source']} -> {r['txt']} ({r['segments']} segments) "
              f"[доставка: {delivery}]{tail}")
        # Провал доставки раньше был невидим: _deliver ловит ошибку сам, а OK
        # печатался всегда. Теперь дублируем в stderr, чтобы строка попала в
        # хвост лога и в текст ошибки в меню приложения.
        if delivery.startswith("failed"):
            delivery_failed = True
            print(f"WARN {r['source']}: доставка в Telegram не удалась — {delivery}",
                  file=sys.stderr)
    for e in result["errors"]:
        print(f"FAIL {e['source']}: {e['error']}", file=sys.stderr)
    if result.get("identify_error"):
        print(f"WARN база голосов не прочитана, имена не подставлены — "
              f"{result['identify_error']}", file=sys.stderr)
    # Исчерпавшие лимит попыток: больше не досылаются, транскрипт остаётся на диске.
    given_up = result.get("given_up", [])
    for g in given_up:
        print(f"GIVEUP {g['base']}: не доставлено за {MAX_ATTEMPTS} попыт(ки) — "
              f"транскрипт на диске: {g['txt']}", file=sys.stderr)
    # Очередь недоставленного: транскрипты сохранены, уйдут автоматически при появлении сети.
    pending = result.get("pending", [])
    if pending:
        print(f"WARN в очереди на доставку: {len(pending)} — {', '.join(pending)} "
              f"(доставятся сами при появлении сети)", file=sys.stderr)
    # Непустая очередь сама по себе — не ошибка прогона, а штатное ожидание сети.
    # Раньше она давала exit 1, а приложение считало ненулевой код поводом показать
    # уведомление и тут же перезапустить worker — получался busy-loop на каждом обрыве.
    return 1 if (result["errors"] or delivery_failed or given_up) else 0


if __name__ == "__main__":
    raise SystemExit(main())
