"""Маскировка секретов в текстах ошибок/логов.

requests кладёт полный URL в текст исключения — а в URL Telegram зашит токен бота
(`.../bot<token>/sendDocument`). Такой текст попадает в worker.log и в сообщения об
ошибке. Перед логированием прогоняем строку через redact().
"""

import re

# Токен бота Telegram в URL/тексте: bot<digits>:<token>
_BOT_TOKEN = re.compile(r"bot\d{6,}:[A-Za-z0-9_-]{20,}")
# HuggingFace-токен (может всплыть в ошибках pyannote/hub)
_HF_TOKEN = re.compile(r"hf_[A-Za-z0-9]{20,}")
# Ключ модели: заголовок Authorization целиком и OpenRouter/подобные ключи sk-… (этап 4, FR-12.13)
_BEARER = re.compile(r"Bearer\s+[A-Za-z0-9._-]{8,}", re.IGNORECASE)
_SK_KEY = re.compile(r"sk-[A-Za-z0-9_-]{8,}")


def redact(text) -> str:
    """Заменить известные токены на плейсхолдеры. Безопасно для любого типа."""
    t = str(text)
    t = _BOT_TOKEN.sub("bot<redacted>", t)
    t = _HF_TOKEN.sub("hf_<redacted>", t)
    t = _BEARER.sub("Bearer <redacted>", t)
    t = _SK_KEY.sub("sk-<redacted>", t)
    return t
