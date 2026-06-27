"""Доставка результатов в Telegram (всегда файлом). Sender инъектируется для тестов."""

from pathlib import Path
from typing import Callable, Optional


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
