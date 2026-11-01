"""Тесты P2: OpenAI-совместимый провайдер на httpx.MockTransport — без сети и ключей."""

import json

import httpx
import pytest

from mlaud_worker.prompter.providers import (OpenAICompatibleProvider, classify_http_error,
                                             estimate_cost, normalize_usage)
from mlaud_worker.prompter.types import Connection, ProviderError, TurnRequest, Usage

CONNECTION = Connection(base_url="https://openrouter.ai/api/v1", model="m/x", reasoning=None)
LOCAL = Connection(base_url="http://127.0.0.1:8080", model="qwen3", reasoning=None)


def _sse(*chunks, usage=None, done=True) -> bytes:
    lines = []
    for c in chunks:
        lines.append(f'data: {json.dumps({"choices": [{"delta": {"content": c}}]})}\n\n')
    if usage is not None:
        lines.append(f"data: {json.dumps({'choices': [], 'usage': usage})}\n\n")
    if done:
        lines.append("data: [DONE]\n\n")
    return "".join(lines).encode()


def _request(schema=None, stream=True, tag="turn", messages=None):
    return TurnRequest(messages=messages or [
        {"role": "system", "content": "s"},
        {"role": "user", "content": "вопрос"},
    ], schema=schema, stream=stream, tag=tag)


def test_endpoint_for_gateway_and_local():
    assert OpenAICompatibleProvider(CONNECTION, "k").endpoint == "/chat/completions"
    assert OpenAICompatibleProvider(LOCAL, "k").endpoint == "/v1/chat/completions"
    assert OpenAICompatibleProvider(
        Connection(base_url="https://openrouter.ai/api/v1/", model="m", reasoning=None), "k").endpoint == "/chat/completions"


def test_build_body_openrouter_flags():
    provider = OpenAICompatibleProvider(CONNECTION, "k")
    body = provider.build_body(_request(schema={"type": "object"}))
    assert body["usage"] == {"include": True}
    assert "cache_prompt" not in body
    assert body["response_format"]["type"] == "json_schema"
    assert body["response_format"]["json_schema"]["name"] == "turn"
    assert body["stream"] is True and body["stream_options"] == {"include_usage": True}
    assert body["temperature"] == 0.3 and body["max_tokens"] == 1200


def test_build_body_local_cache_prompt():
    provider = OpenAICompatibleProvider(LOCAL, "k")
    body = provider.build_body(_request(schema={"type": "object"}))
    assert body["cache_prompt"] is True
    assert "usage" not in body


def test_build_body_reasoning_object_passthrough_and_absent():
    with_reasoning = Connection(base_url="https://openrouter.ai/api/v1", model="m",
                                reasoning={"enabled": False})
    body = OpenAICompatibleProvider(with_reasoning, "k").build_body(_request())
    assert body["reasoning"] == {"enabled": False}
    body = OpenAICompatibleProvider(CONNECTION, "k").build_body(_request())
    assert "reasoning" not in body


def test_build_body_no_response_format_without_schema():
    provider = OpenAICompatibleProvider(CONNECTION, "k")
    assert "response_format" not in provider.build_body(_request(schema=None))


def test_stream_collects_text_ttft_usage():
    provider = OpenAICompatibleProvider(
        CONNECTION, "k",
        transport=httpx.MockTransport(lambda req: httpx.Response(200, content=_sse(
            "кар", "точ", "ка",
            usage={"prompt_tokens": 100, "completion_tokens": 3,
                   "prompt_tokens_details": {"cached_tokens": 90}}))),
        clock=lambda: 0.0)
    deltas = []
    result = provider.complete(_request(schema={"type": "object"}), on_delta=deltas.append)
    assert result.text == "карточка"
    assert deltas == ["кар", "точ", "ка"]
    assert result.usage.cached_tokens == 90
    assert result.format_used == "json_schema"


def test_format_fallback_on_schema_rejection_appends_hint_and_remembers():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        calls.append(body)
        if len(calls) == 1:
            return httpx.Response(400, text='{"error": "response_format not supported"}')
        return httpx.Response(200, content=_sse("{}"))

    provider = OpenAICompatibleProvider(CONNECTION, "k", transport=httpx.MockTransport(handler))
    original = _request(schema={"type": "object"})
    provider.complete(original, on_delta=lambda _: None)
    assert len(calls) == 2
    assert calls[1]["response_format"] == {"type": "json_object"}
    assert "JSON" in calls[1]["messages"][-1]["content"]        # подсказка дописана
    assert "JSON" not in calls[0]["messages"][-1]["content"]
    assert original.messages[-1]["content"] == calls[0]["messages"][-1]["content"]  # история не мутирована
    # Следующий complete сразу идёт с json_object.
    provider.complete(_request(schema={"type": "object"}), on_delta=lambda _: None)
    assert calls[2]["response_format"] == {"type": "json_object"}
    assert len(calls[2]["messages"][-1]["content"]) == len("вопрос")   # без подсказки — новый запрос


def test_reasoning_400_is_fatal_not_fallback():
    provider = OpenAICompatibleProvider(
        CONNECTION, "k", transport=httpx.MockTransport(
            lambda req: httpx.Response(400, text="reasoning cannot be disabled for this model")))
    with pytest.raises(ProviderError) as info:
        provider.complete(_request(schema={"type": "object"}), on_delta=lambda _: None)
    assert info.value.fatal
    assert "effort: low" in info.value.message


def test_401_fatal():
    provider = OpenAICompatibleProvider(CONNECTION, "k",
                                        transport=httpx.MockTransport(lambda req: httpx.Response(401, text="bad key")))
    with pytest.raises(ProviderError) as info:
        provider.complete(_request(schema={"type": "object"}), on_delta=lambda _: None)
    assert info.value.fatal and info.value.status_code == 401


def test_5xx_retry_in_sec():
    provider = OpenAICompatibleProvider(CONNECTION, "k",
                                        transport=httpx.MockTransport(lambda req: httpx.Response(503, text="boom")))
    with pytest.raises(ProviderError) as info:
        provider.complete(_request(schema={"type": "object"}), on_delta=lambda _: None)
    assert not info.value.fatal and info.value.retry_in_sec == 10


def test_429_retry_after():
    provider = OpenAICompatibleProvider(
        CONNECTION, "k",
        transport=httpx.MockTransport(lambda req: httpx.Response(429, text="rate",
                                                                  headers={"Retry-After": "35"})))
    with pytest.raises(ProviderError) as info:
        provider.complete(_request(schema={"type": "object"}), on_delta=lambda _: None)
    assert info.value.retry_in_sec == 35


def test_connect_error_retry():
    def raise_connect(request):
        raise httpx.ConnectError("no route to host")
    provider = OpenAICompatibleProvider(CONNECTION, "k", transport=httpx.MockTransport(raise_connect))
    with pytest.raises(ProviderError) as info:
        provider.complete(_request(schema={"type": "object"}), on_delta=lambda _: None)
    assert info.value.retry_in_sec == 10 and not info.value.fatal


def test_normalize_usage_variants():
    deepseek = normalize_usage({"prompt_tokens": 1000, "prompt_cache_hit_tokens": 800,
                                "completion_tokens": 50})
    assert (deepseek.cached_tokens, deepseek.prompt_tokens) == (800, 1000)
    openrouter = normalize_usage({"prompt_tokens": 1000,
                                  "prompt_tokens_details": {"cached_tokens": 700}})
    assert openrouter.cached_tokens == 700
    llamacpp = normalize_usage({"prompt_tokens": 1000}, timings={"prompt_n": 400})
    assert llamacpp.cached_tokens == 600
    with_cost = normalize_usage({"prompt_tokens": 10, "cost": 0.001})
    assert with_cost.cost_usd == 0.001
    assert normalize_usage({}).cached_tokens == 0


def test_estimate_cost_gateway_cost_wins():
    usage = Usage(prompt_tokens=1000, completion_tokens=10, cost_usd=0.002)
    pricey = Connection(base_url="x", model="m", reasoning=None, price_in=100, price_out=100)
    assert estimate_cost(usage, pricey) == 0.002


def test_estimate_cost_prices():
    connection = Connection(base_url="x", model="m", reasoning=None, price_in=1.0, price_out=2.0)
    usage = Usage(prompt_tokens=1_000_000, cached_tokens=200_000, completion_tokens=100_000)
    uncached = 800_000
    expected = (uncached * 1.0 + 200_000 * 0.1 + 100_000 * 2.0) / 1e6
    assert abs(estimate_cost(usage, connection) - expected) < 1e-12
    with_cached_price = Connection(base_url="x", model="m", reasoning=None, price_in=1.0, price_out=2.0, price_cached=0.05)
    expected2 = (uncached * 1.0 + 200_000 * 0.05 + 100_000 * 2.0) / 1e6
    assert abs(estimate_cost(usage, with_cached_price) - expected2) < 1e-12


def test_estimate_cost_none_without_prices():
    assert estimate_cost(Usage(prompt_tokens=10), Connection(base_url="x", model="m", reasoning=None)) is None


def test_check_returns_ttft():
    provider = OpenAICompatibleProvider(
        CONNECTION, "k", transport=httpx.MockTransport(
            lambda req: httpx.Response(200, content=_sse("ок"))),
        clock=lambda: 0.0)
    assert provider.check() == {"ok": True, "ttft_ms": 0, "model": "m/x"}


def test_classify_unknown_4xx_is_fatal():
    error = classify_http_error(418, "teapot")
    assert error.fatal
