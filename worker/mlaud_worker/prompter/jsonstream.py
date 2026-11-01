"""Инкрементальный разбор стрима ответа: карточки отдаются по мере закрытия объектов
внутри `"cards": [ … ]`. Скобки и кавычки внутри строк не считаются."""

import json
import re
from typing import Optional

_FENCE_RE = re.compile(r"^```[A-Za-z]*[ \t]*\r?\n?|\r?\n?[ \t]*```$")


class CardStream:
    """Кормится дельтами стрима; отдаёт объекты карточек по мере закрытия `{…}` внутри
    `"cards": [ … ]`. Учитывает строки и экранирование; ```-ограждение в начале срезается
    (всё до первого `{` пропускается). После закрытия `]` массива cards новых карточек нет."""

    def __init__(self) -> None:
        self._text = ""
        self._started = False            # первый `{` уже встречен
        self._depth = 0                  # вложенность {} и [] вне строк
        self._in_string = False
        self._escape = False
        self._string_start = -1
        self._last_key: Optional[str] = None   # последняя закрытая строка на глубине 1
        self._in_cards = False
        self._cards_done = False
        self._card_start = -1

    @property
    def text(self) -> str:
        return self._text

    def feed(self, delta: str) -> list:
        """0..n закрывшихся карточек (json.loads среза); битый объект → пропуск."""
        cards = []
        for ch in delta:
            index = len(self._text)
            self._text += ch
            if self._cards_done:
                continue
            if not self._started:
                if ch == "{":
                    self._started = True
                    self._depth = 1
                continue
            if self._in_string:
                if self._escape:
                    self._escape = False
                elif ch == "\\":
                    self._escape = True
                elif ch == '"':
                    self._in_string = False
                    if self._depth == 1:
                        self._last_key = self._text[self._string_start + 1:index]
                continue
            if ch == '"':
                self._in_string = True
                self._string_start = index
            elif ch in "{[":
                if self._in_cards and self._depth == 2 and ch == "{":
                    self._card_start = index
                if ch == "[" and self._depth == 1 and self._last_key == "cards" and not self._in_cards:
                    self._in_cards = True
                self._depth += 1
            elif ch in "}]":
                self._depth -= 1
                if self._in_cards and self._depth == 2 and ch == "}" and self._card_start >= 0:
                    card = _load_object(self._text[self._card_start:index + 1])
                    self._card_start = -1
                    if card is not None:
                        cards.append(card)
                elif self._in_cards and self._depth == 1 and ch == "]":
                    self._in_cards = False
                    self._cards_done = True
                if self._depth <= 0:
                    self._cards_done = True
        return cards


def _load_object(text: str) -> Optional[dict]:
    try:
        obj = json.loads(text)
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def split_reply(text: str) -> tuple:
    """(объект, точный JSON-срез ответа, хвост) — срез идёт в историю беседы как ответ
    модели, поэтому не пересобирается через json.dumps."""
    stripped = _FENCE_RE.sub("", text.strip()).strip()
    start = stripped.find("{")
    if start < 0:
        raise ValueError("в ответе нет JSON-объекта")
    data, end = json.JSONDecoder().raw_decode(stripped, start)
    if not isinstance(data, dict):
        raise ValueError("первое значение ответа не объект")
    return data, stripped[start:end], stripped[end:].strip()


def parse_reply(text: str) -> tuple:
    """Срез ```json … ```, raw_decode первого объекта; хвост после него — отдельно.
    Нет объекта → ValueError."""
    data, _, tail = split_reply(text)
    return data, tail
