"""Подставная модель для тестов оркестратора и сквозного теста — без сети."""

import json
from dataclasses import dataclass, field, replace
from typing import Optional

from .types import ProviderError, ProviderResult, TurnRequest, Usage

DEFAULT_CARD = {"type": "answer", "priority": 1, "text": "Подставная подсказка", "source": ""}
CHUNK = 7


@dataclass
class FakeReply:
    text: str = ""                     # полный текст ответа; пусто → валидный JSON по CARDS_SCHEMA с 1 карточкой
    chunks: Optional[list] = None      # как резать на дельты; None → по CHUNK символов
    usage: Usage = field(default_factory=lambda: Usage(31400, 300, 31000, 0, 0.001))
    ttft_ms: int = 800
    latency_ms: int = 2500
    error: Optional[ProviderError] = None   # вместо ответа — исключение


class FakeProvider:
    def __init__(self, replies: Optional[list] = None, *, default: Optional[FakeReply] = None,
                 default_model: str = "fake/model"):
        self.replies = list(replies or [])
        self.default = default or FakeReply()
        self.default_model = default_model
        self.requests: list = []

    def complete(self, request: TurnRequest, on_delta) -> ProviderResult:
        """Берёт replies.pop(0) или default; зовёт on_delta по chunks."""
        self.requests.append(request)
        reply = self.replies.pop(0) if self.replies else self.default
        if reply.error is not None:
            raise reply.error
        if reply.text:
            text = reply.text
        elif reply.chunks:
            text = "".join(reply.chunks)
        else:
            text = self.cards_json([dict(DEFAULT_CARD)])
        chunks = reply.chunks if reply.chunks is not None else [text[i:i + CHUNK] for i in range(0, len(text), CHUNK)]
        for chunk in chunks:
            on_delta(chunk)
        return ProviderResult(
            text=text,
            usage=replace(reply.usage),
            ttft_ms=reply.ttft_ms,
            latency_ms=reply.latency_ms,
            format_used="json_schema" if request.schema is not None else None,
        )

    def check(self) -> dict:
        return {"ok": True, "ttft_ms": 800, "model": self.default_model}

    @staticmethod
    def cards_json(cards: list, agenda=(), question_pending: bool = False) -> str:
        return json.dumps({"cards": list(cards), "agenda": list(agenda),
                           "flags": {"question_pending": bool(question_pending)}}, ensure_ascii=False)

    @staticmethod
    def outcome_json(goal_result: str = "partial", **fields) -> str:
        data = {"goal_result": goal_result, "reason": "", "summary": "", "decisions": [],
                "next_steps": [], "open_questions": [], "assessment": []}
        data.update(fields)
        return json.dumps(data, ensure_ascii=False)
