"""Авторизация: система реагирует только на владельца (единственный chat_id).

Telegram не умеет ограничивать, КТО пишет боту, — это делается здесь, на уровне приложения.
Любой входящий update от чужого chat_id отбрасывается. Исходящие сообщения идут только владельцу.
"""

from typing import Optional


def is_owner(chat_id, owner_id) -> bool:
    """True только если chat_id точно совпадает с владельцем."""
    if owner_id is None or chat_id is None:
        return False
    try:
        return int(chat_id) == int(owner_id)
    except (TypeError, ValueError):
        return False


def extract_chat_id(update: dict) -> Optional[int]:
    """Достать chat_id из любого вида update Telegram."""
    msg = (
        update.get("message")
        or update.get("edited_message")
        or update.get("channel_post")
        or update.get("callback_query", {}).get("message")
        or {}
    )
    chat = msg.get("chat") or {}
    return chat.get("id")


def filter_owner_updates(updates: list, owner_id) -> list:
    """Оставить только update'ы от владельца; чужие — отбросить."""
    return [u for u in updates if is_owner(extract_chat_id(u), owner_id)]
