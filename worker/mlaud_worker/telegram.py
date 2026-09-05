"""Доставка результатов в Telegram (всегда файлом). Sender инъектируется для тестов.

`python -m mlaud_worker.telegram --test` — тестовое сообщение из настроек приложения:
токен и chat_id берутся из окружения (MLAUD_TG_TOKEN, MLAUD_TG_CHAT_ID), как их передаёт
приложение worker'у.
"""

import os
import sys
from pathlib import Path
from typing import Callable, Optional

TEST_TEXT = "проверка связи из настроек"


def _real_sender(token: str, chat_id: str, file_path: str, caption: Optional[str]) -> dict:
    """Реальная отправка через Telegram Bot API (sendDocument)."""
    import requests

    url = f"https://api.telegram.org/bot{token}/sendDocument"
    with open(file_path, "rb") as f:
        data = {"chat_id": chat_id}
        if caption:
            data["caption"] = caption[:1024]
        resp = requests.post(url, data=data, files={"document": f}, timeout=60)
    resp.raise_for_status()
    return resp.json()


def _real_message(token: str, chat_id: str, text: str) -> dict:
    import requests

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    resp = requests.post(url, data={"chat_id": chat_id, "text": text[:4096]}, timeout=60)
    resp.raise_for_status()
    return resp.json()


class TelegramNotifier:
    """Отправка документов/ошибок. sender/messenger можно подменить в тестах."""

    def __init__(self, token: str, chat_id: str,
                 sender: Optional[Callable] = None,
                 messenger: Optional[Callable] = None):
        self.token = token
        self.chat_id = chat_id
        self._sender = sender or _real_sender
        self._messenger = messenger or _real_message

    def send_document(self, file_path, caption: Optional[str] = None) -> dict:
        return self._sender(self.token, self.chat_id, str(Path(file_path)), caption)

    def send_message(self, text: str) -> dict:
        """Нейтральное текстовое сообщение (напр. «речь не распознана»)."""
        return self._messenger(self.token, self.chat_id, f"MLaud: {text}")

    def send_error(self, text: str) -> dict:
        return self._messenger(self.token, self.chat_id, f"⚠️ MLaud: {text}")


def main(argv: Optional[list] = None, messenger: Optional[Callable] = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="python -m mlaud_worker.telegram")
    parser.add_argument("--test", action="store_true",
                        help="отправить тестовое сообщение и выйти")
    args = parser.parse_args(argv)
    if not args.test:
        parser.print_help()
        return 2
    token = os.environ.get("MLAUD_TG_TOKEN", "").strip()
    chat_id = os.environ.get("MLAUD_TG_CHAT_ID", "").strip()
    if not token or not chat_id:
        print("токен или chat_id не заданы", file=sys.stderr)
        return 2
    try:
        TelegramNotifier(token, chat_id, messenger=messenger).send_message(TEST_TEXT)
    except Exception as e:  # сеть, отказ API — причина нужна пользователю, не трассировка
        print(f"не отправилось: {e}", file=sys.stderr)
        return 1
    print("отправлено")
    return 0


if __name__ == "__main__":
    sys.exit(main())
