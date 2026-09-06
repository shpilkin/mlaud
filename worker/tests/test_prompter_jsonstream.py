"""Тесты P2: инкрементальный разбор стрима карточек и разбор ответа; маскировка ключей."""

import pytest

from mlaud_worker.logutil import redact
from mlaud_worker.prompter.jsonstream import CardStream, parse_reply


def test_cardstream_emits_on_object_close_string_aware():
    stream = CardStream()
    text = ('{"cards": [{"type": "answer", "priority": 1, "text": "скобки ]{ и кавычка \\" внутри", '
            '"source": ""}], "agenda": [], "flags": {"question_pending": false}}')
    cards = []
    for ch in text:                       # дельты по 1 символу
        cards += stream.feed(ch)
    assert len(cards) == 1
    assert cards[0]["text"] == 'скобки ]{ и кавычка " внутри'
    assert stream.text == text


def test_cardstream_ignores_after_array_end():
    stream = CardStream()
    text = '{"cards": [{"type": "ask", "priority": 1, "text": "a", "source": ""}], "extra": {"x": {"y": 1}}}'
    cards = []
    for ch in text:
        cards += stream.feed(ch)
    assert len(cards) == 1
    tail = stream.feed('{"another": [{"deep": true}]}')
    assert tail == []                     # после закрытия массива cards карточек нет


def test_cardstream_broken_object_skipped():
    stream = CardStream()
    text = '{"cards": [{"type": "fact", "priority": 1, "text": "ок", "source": ""}, НЕJSON], "agenda": []}'
    cards = []
    for ch in text:
        cards += stream.feed(ch)
    assert len(cards) == 1                # битый объект пропущен, валидный отдан


def test_parse_reply_strips_fences_and_tail():
    data, tail = parse_reply('```json\n{"cards": [], "agenda": []}\n```\n\nпояснение')
    assert data == {"cards": [], "agenda": []}
    assert tail == "```\n\nпояснение"      # закрывающее ограждение — часть хвоста, не ответа
    with pytest.raises(ValueError):
        parse_reply("просто текст без объекта")


def test_redact_masks_bearer_and_sk_keys():
    text = "Authorization: Bearer sk-or-v1-abcdef1234567890ABCD failed for sk-abc12345678"
    masked = redact(text)
    assert "sk-or-v1" not in masked
    assert "Bearer <redacted>" in masked
    assert "sk-<redacted>" in masked
