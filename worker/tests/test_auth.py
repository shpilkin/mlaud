"""Тесты allowlist по владельцу: только владелец может взаимодействовать с ботом."""

from mlaud_worker.auth import is_owner, extract_chat_id, filter_owner_updates

OWNER = 123456789  # вымышленный chat_id


def test_is_owner_match():
    assert is_owner(OWNER, OWNER) is True
    assert is_owner(str(OWNER), OWNER) is True   # строковый id тоже совпадает


def test_is_owner_reject():
    assert is_owner(999, OWNER) is False
    assert is_owner(None, OWNER) is False
    assert is_owner(OWNER, None) is False
    assert is_owner("not-a-number", OWNER) is False


def test_extract_chat_id_variants():
    assert extract_chat_id({"message": {"chat": {"id": OWNER}}}) == OWNER
    assert extract_chat_id({"edited_message": {"chat": {"id": 7}}}) == 7
    assert extract_chat_id({"callback_query": {"message": {"chat": {"id": 8}}}}) == 8
    assert extract_chat_id({"weird": {}}) is None


def test_filter_owner_updates_drops_strangers():
    updates = [
        {"message": {"chat": {"id": OWNER}, "text": "мой"}},
        {"message": {"chat": {"id": 4242}, "text": "чужой"}},      # посторонний
        {"message": {"chat": {"id": OWNER}, "text": "тоже мой"}},
    ]
    kept = filter_owner_updates(updates, OWNER)
    assert len(kept) == 2
    assert all(extract_chat_id(u) == OWNER for u in kept)
