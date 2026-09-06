"""OpenAI-совместимый провайдер (OpenRouter, llama.cpp) — poc/prompter-latency/run.py:402-528
без Anthropic/Niti/файлов. Один экземпляр на сессию: помнит fmt_idx (какой response_format
шлюз принял). Ключ не логируется; тексты исключений httpx идут через logutil.redact."""

import json
import time
from typing import Callable, Optional

import httpx

from ..logutil import redact
from .types import Connection, OnDelta, ProviderError, ProviderResult, TurnRequest, Usage


class FormatRejected(Exception):
    """Внутренний сигнал: шлюз отверг response_format — перейти к следующему формату."""


class _FallbackFormat(Exception):
    """Из _exchange в complete: формат отвергнут, fmt_idx уже сдвинут, нужен повтор."""


class _HttpError(Exception):
    def __init__(self, status: int, text: str, retry_after: Optional[str] = None):
        super().__init__(f"HTTP {status}")
        self.status = status
        self.text = text
        self.retry_after = retry_after


def normalize_usage(raw: dict, timings: Optional[dict] = None) -> Usage:
    """run.py:484-489: кэш из prompt_cache_hit_tokens → prompt_tokens_details.cached_tokens →
    cache_read_input_tokens → prompt_tokens − timings.prompt_n → 0."""
    raw = raw or {}
    timings = timings or {}
    details = raw.get("prompt_tokens_details") or {}
    completion_details = raw.get("completion_tokens_details") or {}
    if raw.get("prompt_cache_hit_tokens"):
        cached = raw["prompt_cache_hit_tokens"]
    elif details.get("cached_tokens"):
        cached = details["cached_tokens"]
    elif raw.get("cache_read_input_tokens"):
        cached = raw["cache_read_input_tokens"]
    elif timings.get("prompt_n") is not None:
        cached = max(0, raw.get("prompt_tokens", 0) - timings["prompt_n"])
    else:
        cached = 0
    cost = raw.get("cost") if isinstance(raw.get("cost"), (int, float)) else None
    return Usage(
        prompt_tokens=int(raw.get("prompt_tokens", 0) or 0),
        completion_tokens=int(raw.get("completion_tokens", 0) or 0),
        cached_tokens=int(cached or 0),
        reasoning_tokens=int(completion_details.get("reasoning_tokens", 0) or 0),
        cost_usd=float(cost) if cost is not None else None,
    )


def estimate_cost(usage: Usage, connection: Connection) -> Optional[float]:
    """usage.cost шлюза верим; иначе по ценам: (uncached·in + cached·cached + out·out)/1e6;
    цена кэша не задана → in·0.1 (run.py:404, 493); нет цен → None."""
    if usage.cost_usd is not None:
        return usage.cost_usd
    if connection.price_in is None or connection.price_out is None:
        return None
    cached_price = connection.price_cached
    if cached_price is None:
        cached_price = connection.price_in * 0.1
    uncached = max(0, usage.prompt_tokens - usage.cached_tokens)
    return (uncached * connection.price_in + usage.cached_tokens * cached_price
            + usage.completion_tokens * connection.price_out) / 1e6


def classify_http_error(status: int, text: str) -> ProviderError:
    """FR-12.16: 401/403 — ключ отвергнут; 404 — модель; 400/422 с «reasoning» — выключить
    нельзя; с «response_format»/«schema» — FormatRejected; 429/5xx — повторить."""
    if status in (401, 403):
        return ProviderError("ключ отвергнут шлюзом", fatal=True, status_code=status)
    if status == 404:
        return ProviderError("модель не найдена", fatal=True, status_code=status)
    if status in (400, 422):
        lowered = text.lower()
        if "reasoning" in lowered:
            return ProviderError(
                "рассуждения нельзя выключить у этой модели — поставьте effort: low",
                fatal=True, status_code=status)
        if "response_format" in lowered or "json_schema" in lowered or "schema" in lowered:
            raise FormatRejected()
    if status == 429:
        return ProviderError("слишком много запросов", retry_in_sec=20, status_code=status)
    if status >= 500:
        return ProviderError(f"шлюз ответил {status}", retry_in_sec=10, status_code=status)
    return ProviderError(f"шлюз ответил {status}: {redact(text)[:200]}", fatal=True, status_code=status)


class OpenAICompatibleProvider:
    FORMATS = ("json_schema", "json_object", None)

    def __init__(self, connection: Connection, api_key: str, *,
                 transport: Optional[httpx.BaseTransport] = None,
                 timeout: httpx.Timeout = httpx.Timeout(connect=10.0, read=60.0, write=10.0, pool=10.0),
                 clock: Callable[[], float] = time.perf_counter):
        self.connection = connection
        self._api_key = api_key
        self._clock = clock
        self.fmt_idx = 0
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self._client = httpx.Client(base_url=connection.base_url, timeout=timeout,
                                    headers=headers, transport=transport)

    @property
    def endpoint(self) -> str:
        # У шлюзов base_url уже содержит /v1, у llama.cpp — только хост (run.py:420).
        if self.connection.base_url.rstrip("/").endswith("/v1"):
            return "/chat/completions"
        return "/v1/chat/completions"

    def build_body(self, request: TurnRequest) -> dict:
        """Чистая: параметры запроса → тело шлюза (run.py:447-457)."""
        body = {"model": self.connection.model,
                "messages": request.messages,
                "max_tokens": request.max_tokens,
                "temperature": 0.3}
        fmt = self.FORMATS[self.fmt_idx]
        if request.schema is not None and fmt is not None:
            if fmt == "json_schema":
                body["response_format"] = {"type": "json_schema",
                                           "json_schema": {"name": request.tag, "schema": request.schema,
                                                           "strict": True}}
            else:
                body["response_format"] = {"type": "json_object"}
        if self.connection.reasoning is not None:
            body["reasoning"] = self.connection.reasoning
        if "openrouter.ai" in self.connection.base_url:
            body["usage"] = {"include": True}
        if "localhost" in self.connection.base_url or "127.0.0.1" in self.connection.base_url:
            body["cache_prompt"] = True
        if request.stream:
            body["stream"] = True
            body["stream_options"] = {"include_usage": True}
        return body

    def complete(self, request: TurnRequest, on_delta: OnDelta) -> ProviderResult:
        messages = [dict(m) for m in request.messages]
        while True:
            body = self.build_body(request)
            body["messages"] = messages
            t0 = self._clock()
            try:
                text, usage_raw, timings, ttft = self._exchange(body, request, on_delta, t0)
            except _FallbackFormat:
                # Подсказка схемы дописывается к копии последнего user-сообщения (run.py:437, 466);
                # исходная история не мутирует.
                messages = [dict(m) for m in messages]
                hint = "\n\nОтвет — только JSON по схеме, без пояснений и без ```:\n" + \
                    json.dumps(request.schema, ensure_ascii=False)
                for i in range(len(messages) - 1, -1, -1):
                    if messages[i].get("role") == "user":
                        messages[i]["content"] = messages[i]["content"] + hint
                        break
                continue
            usage = normalize_usage(usage_raw, timings)
            latency = int((self._clock() - t0) * 1000)
            return ProviderResult(
                text=text, usage=usage, ttft_ms=ttft, latency_ms=latency,
                format_used=self.FORMATS[self.fmt_idx] if request.schema is not None else None)

    def _exchange(self, body: dict, request: TurnRequest, on_delta: OnDelta, t0: float):
        """Один обмен; ошибки шлюза → ProviderError (после Retry-After), формат — _FallbackFormat."""
        try:
            if request.stream:
                return self._stream_exchange(body, request, on_delta, t0)
            return self._plain_exchange(body, request, t0)
        except _HttpError as e:
            try:
                error = classify_http_error(e.status, e.text)
            except FormatRejected:
                if self.fmt_idx < len(self.FORMATS) - 1:
                    self.fmt_idx += 1
                    raise _FallbackFormat()
                raise ProviderError("шлюз не принимает ни один формат ответа", fatal=True,
                                    status_code=e.status)
            if e.retry_after:
                try:
                    error.retry_in_sec = max(error.retry_in_sec or 0, int(e.retry_after))
                except ValueError:
                    pass
            raise error
        except (httpx.TransportError, httpx.TimeoutException) as e:
            raise ProviderError(f"сеть: {redact(e)}", retry_in_sec=10)

    def _stream_exchange(self, body: dict, request: TurnRequest, on_delta: OnDelta, t0: float):
        acc = ""
        ttft = None
        usage_raw = None
        timings = {}
        with self._client.stream("POST", self.endpoint, json=body) as response:
            if response.status_code >= 400:
                try:
                    response.read()
                    raise _HttpError(response.status_code, response.text,
                                     response.headers.get("Retry-After"))
                except httpx.HTTPError:
                    raise _HttpError(response.status_code, "", response.headers.get("Retry-After"))
            for line in response.iter_lines():
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except ValueError:
                    continue
                if isinstance(chunk.get("usage"), dict):
                    usage_raw = chunk["usage"]
                if isinstance(chunk.get("timings"), dict):
                    timings = chunk["timings"]
                for choice in chunk.get("choices", []):
                    delta = (choice.get("delta") or {}).get("content") or ""
                    if not delta:
                        continue
                    if ttft is None:
                        ttft = int((self._clock() - t0) * 1000)
                    acc += delta
                    on_delta(delta)
        return acc, usage_raw or {}, timings, ttft

    def _plain_exchange(self, body: dict, request: TurnRequest, t0: float):
        response = self._client.post(self.endpoint, json=body)
        if response.status_code >= 400:
            raise _HttpError(response.status_code, response.text, response.headers.get("Retry-After"))
        payload = response.json()
        text = (payload.get("choices") or [{}])[0].get("message", {}).get("content") or ""
        return text, payload.get("usage") or {}, payload.get("timings") or {}, None

    def check(self) -> dict:
        """Для --check (§2.4): один запрос max_tokens=1, стрим; {"ok", "ttft_ms", "model"}."""
        request = TurnRequest(messages=[{"role": "user", "content": "Готов."}],
                              max_tokens=1, schema=None, stream=True, tag="check")
        try:
            result = self.complete(request, on_delta=lambda _: None)
        except ProviderError as e:
            return {"ok": False, "message": e.message}
        return {"ok": True, "ttft_ms": result.ttft_ms or 0, "model": self.connection.model}

    def close(self) -> None:
        self._client.close()
