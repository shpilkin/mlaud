"""Общие типы подсказчика: схемы, инкрементальный разбор стрима, подставной провайдер."""

import json

import pytest

from mlaud_worker.prompter.fake import FakeProvider, FakeReply
from mlaud_worker.prompter.jsonstream import CardStream, parse_reply
from mlaud_worker.prompter.schema import (CARDS_SCHEMA, DETAIL_SCHEMA, OUTCOME_SCHEMA, validate_cards,
                                          validate_outcome)
from mlaud_worker.prompter.types import Connection, Limits, ProviderError, TurnRequest, Usage


# --- types ---------------------------------------------------------------------

def test_connection_from_json_prices_and_reasoning():
    c = Connection.from_json({"base_url": "https://openrouter.ai/api/v1", "model": "deepseek/deepseek-v4-flash",
                              "reasoning": {"enabled": False},
                              "price_per_mtok": {"in": None, "out": 0.5, "cached": None}})
    assert c.reasoning == {"enabled": False}
    assert (c.price_in, c.price_out, c.price_cached) == (None, 0.5, None)
    absent = Connection.from_json({"base_url": "http://127.0.0.1:8080", "model": "x", "price_per_mtok": {}})
    assert absent.reasoning is None
    assert (absent.price_in, absent.price_out, absent.price_cached) == (None, None, None)
    null = Connection.from_json({"base_url": "u", "model": "m", "reasoning": None})
    assert null.reasoning is None


def test_limits_from_json_defaults():
    assert Limits.from_json(None) == Limits(6, None, 2.5, 240.0)
    assert Limits.from_json({"rpm": 3, "cost_ceiling_usd": 0.5}) == Limits(3, 0.5, 2.5, 240.0)


def test_usage_to_json_exactly_four_keys_in_order():
    u = Usage(prompt_tokens=33800, completion_tokens=310, cached_tokens=33024, reasoning_tokens=0, cost_usd=0.001)
    j = u.to_json()
    assert list(j.keys()) == ["prompt_tokens", "completion_tokens", "cached_tokens", "reasoning_tokens"]
    assert j == {"prompt_tokens": 33800, "completion_tokens": 310, "cached_tokens": 33024, "reasoning_tokens": 0}
    assert list(Usage().to_json().values()) == [0, 0, 0, 0]


def test_provider_error_fields():
    e = ProviderError("ключ отвергнут", fatal=True, status_code=401)
    assert (e.message, e.fatal, e.retry_in_sec, e.status_code) == ("ключ отвергнут", True, None, 401)
    assert str(e) == "ключ отвергнут"
    r = ProviderError("сеть", retry_in_sec=10)
    assert (r.fatal, r.retry_in_sec) == (False, 10)


def test_turn_request_defaults():
    r = TurnRequest(messages=[{"role": "system", "content": "s"}])
    assert (r.max_tokens, r.schema, r.stream, r.tag) == (1200, None, True, "turn")


# --- schema --------------------------------------------------------------------

def test_schemas_shape():
    assert CARDS_SCHEMA["properties"]["cards"]["maxItems"] == 3
    assert "detail" not in CARDS_SCHEMA["properties"]["cards"]["items"]["properties"]
    assert CARDS_SCHEMA["required"] == ["cards", "agenda", "flags"]
    assert OUTCOME_SCHEMA["required"] == ["goal_result", "reason", "summary", "decisions", "next_steps",
                                          "open_questions", "assessment"]
    assert OUTCOME_SCHEMA["properties"]["goal_result"]["enum"] == ["achieved", "partial", "not"]
    assert DETAIL_SCHEMA["required"] == ["text"]
    json.dumps(CARDS_SCHEMA)


def test_validate_cards_drops_unknown_then_trims_to_three():
    data = {"cards": [
        {"type": "answer", "priority": 1, "text": "a", "source": ""},
        {"type": "joke", "priority": 2, "text": "b", "source": ""},
        {"type": "ask", "priority": "3", "text": 42, "source": None},
        {"type": "fact", "priority": 4, "text": "d", "source": "резюме.pdf"},
        {"type": "time", "priority": 5, "text": "e", "source": ""},
    ], "agenda": [{"item": "Кейс", "status": "done"}, {"item": "x", "status": "later"}, {"status": "done"}],
        "flags": {"question_pending": 1}}
    out = validate_cards(data)
    assert list(out.keys()) == ["cards", "agenda", "flags"]
    assert [c["type"] for c in out["cards"]] == ["answer", "ask", "fact"]
    assert out["cards"][1] == {"type": "ask", "priority": 3, "text": "42", "source": ""}
    assert list(out["cards"][0].keys()) == ["type", "priority", "text", "source"]
    assert out["agenda"] == [{"item": "Кейс", "status": "done"}]
    assert out["flags"] == {"question_pending": True}


def test_validate_cards_requires_top_keys():
    with pytest.raises(ValueError):
        validate_cards({"cards": [], "agenda": []})
    with pytest.raises(ValueError):
        validate_cards({"cards": "x", "agenda": [], "flags": {}})
    with pytest.raises(ValueError):
        validate_cards([])
    assert validate_cards({"cards": [], "agenda": [], "flags": {}}) == {
        "cards": [], "agenda": [], "flags": {"question_pending": False}}


def test_validate_outcome_defaults_and_enum():
    out = validate_outcome({"goal_result": "partial", "reason": "r"})
    assert out == {"goal_result": "partial", "reason": "r", "summary": "", "decisions": [], "next_steps": [],
                   "open_questions": [], "assessment": []}
    assert list(out.keys()) == OUTCOME_SCHEMA["required"]
    full = validate_outcome({"goal_result": "achieved", "reason": "", "summary": "s", "decisions": ["d", 1],
                             "assessment": [{"criterion": "c", "verdict": "v"}, "мусор"]})
    assert full["decisions"] == ["d", "1"]
    assert full["assessment"] == [{"criterion": "c", "verdict": "v", "evidence": ""}]
    with pytest.raises(ValueError):
        validate_outcome({"goal_result": "maybe"})
    with pytest.raises(ValueError):
        validate_outcome("нет")


# --- jsonstream ----------------------------------------------------------------

REPLY = ('{"cards": [{"type": "answer", "priority": 1, "text": "Скобки {и} [тут] и \\"кавычка\\"", "source": ""}, '
         '{"type": "ask", "priority": 2, "text": "Второй", "source": "x"}], '
         '"agenda": [{"item": "Кейс", "status": "done"}], "flags": {"question_pending": true}}')


def test_cardstream_emits_on_object_close_string_aware_one_char_at_a_time():
    s = CardStream()
    seen = []
    closed_at = []
    for i, ch in enumerate(REPLY):
        got = s.feed(ch)
        seen.extend(got)
        if got:
            closed_at.append(i)
    assert [c["type"] for c in seen] == ["answer", "ask"]
    assert seen[0]["text"] == 'Скобки {и} [тут] и "кавычка"'
    assert closed_at[0] == REPLY.index('"source": ""}') + len('"source": ""}') - 1
    assert s.text == REPLY


def test_cardstream_strips_fence_and_ignores_after_array_end():
    s = CardStream()
    text = "```json\n" + REPLY + "\n```"
    seen = []
    for i in range(0, len(text), 5):
        seen.extend(s.feed(text[i:i + 5]))
    assert len(seen) == 2
    # Объекты вне cards (agenda, flags) и что угодно после закрытия массива карточками не считаются.
    assert s.feed('{"type": "fact", "priority": 3, "text": "лишняя", "source": ""}') == []
    assert s.text.endswith('"source": ""}')


def test_cardstream_skips_broken_object():
    s = CardStream()
    got = s.feed('{"cards": [{"type": "answer", "priority": 1, "text": "ok", "source": ""}, {oops}, '
                 '{"type": "ask", "priority": 2, "text": "два", "source": ""}]}')
    assert [c["text"] for c in got] == ["ok", "два"]


def test_parse_reply_strips_fences_and_tail():
    data, tail = parse_reply("```json\n" + REPLY + "\n```\n\nВот подсказки.")
    assert data["flags"] == {"question_pending": True}
    assert tail == "```\n\nВот подсказки." or tail == "Вот подсказки."
    data2, tail2 = parse_reply(REPLY + " хвост")
    assert data2 == json.loads(REPLY)
    assert tail2 == "хвост"
    plain, empty = parse_reply("  " + REPLY + "\n")
    assert (plain == json.loads(REPLY), empty) == (True, "")
    with pytest.raises(ValueError):
        parse_reply("нет json")
    with pytest.raises(ValueError):
        parse_reply("{oops")


# --- fake ----------------------------------------------------------------------

def test_fake_provider_chunks_default_reply_and_order():
    p = FakeProvider([FakeReply(text='{"cards": [], "agenda": [], "flags": {"question_pending": false}}',
                                chunks=["{\"cards\"", ": [], \"agenda\": [], \"flags\": {\"question_pending\": false}}"]),
                      FakeReply(error=ProviderError("сеть", retry_in_sec=10))])
    deltas = []
    req = TurnRequest(messages=[{"role": "system", "content": "s"}], schema=CARDS_SCHEMA)
    r1 = p.complete(req, deltas.append)
    assert deltas == ["{\"cards\"", ": [], \"agenda\": [], \"flags\": {\"question_pending\": false}}"]
    assert r1.text == "".join(deltas) and r1.format_used == "json_schema" and r1.status_code == 200
    with pytest.raises(ProviderError) as e:
        p.complete(req, deltas.append)
    assert e.value.retry_in_sec == 10
    # Список исчерпан — default: валидный JSON с одной карточкой, дельты по 7 символов.
    deltas.clear()
    r3 = p.complete(TurnRequest(messages=[], schema=None, tag="warm"), deltas.append)
    assert all(len(d) == 7 for d in deltas[:-1]) and "".join(deltas) == r3.text
    assert r3.format_used is None
    parsed = validate_cards(json.loads(r3.text))
    assert len(parsed["cards"]) == 1 and parsed["cards"][0]["type"] == "answer"
    assert r3.usage == Usage(31400, 300, 31000, 0, 0.001) and r3.usage is not p.default.usage
    assert (r3.ttft_ms, r3.latency_ms) == (800, 2500)
    assert [r.tag for r in p.requests] == ["turn", "turn", "warm"]


def test_fake_cards_and_outcome_json_are_valid():
    text = FakeProvider.cards_json([{"type": "ask", "priority": 1, "text": "?", "source": ""}],
                                   agenda=[{"item": "Кейс", "status": "active"}], question_pending=True)
    data = validate_cards(json.loads(text))
    assert data["agenda"] == [{"item": "Кейс", "status": "active"}] and data["flags"]["question_pending"] is True
    out = validate_outcome(json.loads(FakeProvider.outcome_json("achieved", summary="кратко")))
    assert (out["goal_result"], out["summary"]) == ("achieved", "кратко")
    assert list(json.loads(FakeProvider.outcome_json()).keys()) == OUTCOME_SCHEMA["required"]
