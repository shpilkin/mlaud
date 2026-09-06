"""Общие типы подсказчика: подключение, лимиты, расход, запрос/ответ провайдера."""

from dataclasses import dataclass
from typing import Callable, Optional, Protocol


def _opt_float(value) -> Optional[float]:
    return None if value is None else float(value)


@dataclass(frozen=True)
class Connection:
    base_url: str                         # https://openrouter.ai/api/v1 | http://127.0.0.1:8080
    model: str
    reasoning: Optional[dict]             # {"enabled": False} | {"effort": "low"} | None — объект как есть
    price_in: Optional[float] = None      # $ за 1M токенов; None → цена только из usage.cost
    price_out: Optional[float] = None
    price_cached: Optional[float] = None  # None → price_in * 0.1

    @staticmethod
    def from_json(obj: dict) -> "Connection":
        """Ключи `start.connection`: price_per_mtok.{in,out,cached} — отсутствующий ключ = null;
        reasoning отсутствует = None."""
        price = obj.get("price_per_mtok") or {}
        reasoning = obj.get("reasoning")
        return Connection(
            base_url=str(obj["base_url"]),
            model=str(obj["model"]),
            reasoning=dict(reasoning) if isinstance(reasoning, dict) else None,
            price_in=_opt_float(price.get("in")),
            price_out=_opt_float(price.get("out")),
            price_cached=_opt_float(price.get("cached")),
        )


@dataclass(frozen=True)
class Limits:
    rpm: int = 6
    cost_ceiling_usd: Optional[float] = None
    debounce_sec: float = 2.5
    warm_every_sec: float = 240.0

    @staticmethod
    def from_json(obj: Optional[dict]) -> "Limits":
        obj = obj or {}
        base = Limits()
        return Limits(
            rpm=int(obj.get("rpm", base.rpm)),
            cost_ceiling_usd=_opt_float(obj.get("cost_ceiling_usd")),
            debounce_sec=float(obj.get("debounce_sec", base.debounce_sec)),
            warm_every_sec=float(obj.get("warm_every_sec", base.warm_every_sec)),
        )


@dataclass
class Usage:
    prompt_tokens: int = 0
    completion_tokens: int = 0
    cached_tokens: int = 0
    reasoning_tokens: int = 0
    cost_usd: Optional[float] = None      # usage.cost шлюза, если отдал (OpenRouter)

    def to_json(self) -> dict:
        """Ровно четыре ключа, в этом порядке; стоимость — отдельным полем события."""
        return {
            "prompt_tokens": int(self.prompt_tokens),
            "completion_tokens": int(self.completion_tokens),
            "cached_tokens": int(self.cached_tokens),
            "reasoning_tokens": int(self.reasoning_tokens),
        }


@dataclass(frozen=True)
class TurnRequest:
    messages: list                        # [{"role","content"}], system первым
    max_tokens: int = 1200
    schema: Optional[dict] = None         # None → без response_format (прогрев, --check)
    stream: bool = True
    tag: str = "turn"                     # "warm" | "turn" | "detail" | "finish" | "check"


@dataclass
class ProviderResult:
    text: str                             # полный текст ответа (content), без обрезки
    usage: Usage
    ttft_ms: Optional[int]
    latency_ms: int
    format_used: Optional[str]            # "json_schema" | "json_object" | None
    status_code: int = 200


class ProviderError(Exception):
    """fatal — без повторов (401/403, 404 модели, нет ключа, «reasoning не выключается»);
    не fatal — сеть, таймаут, 5xx, 429: retry_in_sec обязателен."""

    def __init__(self, message: str, *, fatal: bool = False, retry_in_sec: Optional[int] = None,
                 status_code: Optional[int] = None):
        super().__init__(message)
        self.message = message
        self.fatal = fatal
        self.retry_in_sec = retry_in_sec
        self.status_code = status_code


OnDelta = Callable[[str], None]


class Provider(Protocol):
    def complete(self, request: TurnRequest, on_delta: OnDelta) -> ProviderResult:
        """Блокирующий вызов; on_delta — из того же потока, по мере стрима; может бросить ProviderError."""
        ...
