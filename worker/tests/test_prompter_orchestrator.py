"""Тесты P3: машина хода — дебаунс, копление, лимиты, повторы, прогрев, итоги, файлы звонка.
FakeProvider — без сети; часы и submit — подставные (как _Clock в test_dictate)."""

import json
from pathlib import Path

import pytest

from mlaud_worker.prompter.fake import FakeProvider, FakeReply
from mlaud_worker.prompter.orchestrator import Orchestrator, Request
from mlaud_worker.prompter.types import Connection, Limits, ProviderError, ProviderResult

CONNECTION = Connection(base_url="https://openrouter.ai/api/v1", model="m/x", reasoning=None,
                        price_in=None, price_out=None)


class Clock:
    """Ручные часы: t = start; advance(sec) двигает."""

    def __init__(self, start=100.0):
        self.t = start

    def __call__(self):
        return self.t

    def advance(self, sec):
        self.t += sec


def _orch(tmp_path=None, *, limits=None, clock=None, connection=CONNECTION, expected=60,
          has_criteria=False):
    clock = clock or Clock()
    events, submitted = [], []
    limits = limits or Limits()
    kwargs = {}
    if tmp_path is not None:
        kwargs["call_dir"] = Path(tmp_path)
    orch = Orchestrator(emit=events.append, submit=submitted.append, clock=clock,
                        limits=limits, connection=connection, system_prompt="SYSTEM",
                        expected_min=expected, now_iso=lambda: "2026-09-05T12:00:00+03:00",
                        has_criteria=has_criteria, **kwargs)
    return orch, events, submitted, clock


def _turn(msg_t="them_phrase", lines=None, notes="", elapsed=100, agenda=None):
    return {"t": "turn", "reason": msg_t, "elapsed_sec": elapsed,
            "lines": lines if lines is not None else
            [{"ch": "them", "label": "Иван", "t0": 1, "t1": 2, "text": "вопрос"}],
            "agenda_manual": agenda or [], "notes": notes}


def _reply_cost(cost):
    from mlaud_worker.prompter.types import Usage
    return FakeReply(usage=Usage(cost_usd=cost))


def _result(text=None, usage=None):
    from mlaud_worker.prompter.types import ProviderResult, Usage
    return ProviderResult(text=text if text is not None else FakeProvider.cards_json(
        [{"type": "answer", "priority": 1, "text": "подсказка", "source": ""}]),
        usage=usage or Usage(prompt_tokens=100, completion_tokens=10, cached_tokens=90),
        ttft_ms=500, latency_ms=2000, format_used="json_schema")


def test_them_phrase_fires_once_then_debounces():
    orch, events, submitted, clock = _orch()
    orch.handle(_turn())
    orch.handle(_turn(lines=[{"ch": "them", "label": "И", "t0": 3, "t1": 4, "text": "ещё"}]))
    assert len(submitted) == 1                       # второй копится в полёте
    orch.on_result(orch.in_flight, _result())        # ход завершён — дебаунс от last_start
    assert len(submitted) == 1
    assert orch.next_deadline() == clock.t + 2.5     # last_start + debounce
    clock.advance(2.5)
    orch.tick()
    assert len(submitted) == 2
    second_lines = submitted[1].request.messages[-1]["content"]
    assert "ещё" in second_lines and "вопрос" not in second_lines  # только накопленное
    orch.on_result(submitted[1], _result())
    assert any(e["t"] == "cards" for e in events)


def test_lines_accumulate_while_in_flight_and_go_next_turn():
    orch, _, submitted, clock = _orch()
    orch.handle(_turn())
    assert len(submitted) == 1
    orch.handle(_turn(lines=[{"ch": "me", "label": "Я", "t0": 5, "t1": 6, "text": "ответ"}]))
    assert len(submitted) == 1                       # в полёте — копится
    orch.on_result(submitted[0], _result())
    clock.advance(3)
    orch.tick()
    assert len(submitted) == 2
    assert "ответ" in submitted[1].request.messages[-1]["content"]


def test_turn_without_lines_does_not_fire_unless_manual():
    orch, _, submitted, _ = _orch()
    orch.handle(_turn(lines=[]))
    assert submitted == []                           # them_phrase без реплик — не ход (D18)
    orch.handle({"t": "turn", "reason": "timer", "elapsed_sec": 300, "lines": [],
                 "agenda_manual": [], "notes": ""})
    assert submitted == []
    orch.handle({"t": "turn", "reason": "manual", "elapsed_sec": 300, "lines": [],
                 "agenda_manual": [], "notes": "хочу подсказку"})
    assert len(submitted) == 1                       # manual идёт даже без реплик
    assert "хочу подсказку" in submitted[0].request.messages[-1]["content"]


def test_manual_skips_debounce_but_not_in_flight():
    orch, _, submitted, clock = _orch()
    orch.handle(_turn())
    orch.on_result(orch.in_flight, _result())        # ход завершён
    clock.advance(0.5)                               # меньше дебаунса
    orch.handle({"t": "turn", "reason": "manual", "elapsed_sec": 101, "lines":
                 [{"ch": "them", "label": "И", "t0": 1, "t1": 2, "text": "срочно"}],
                 "agenda_manual": [], "notes": ""})
    assert len(submitted) == 2                       # manual без дебаунса
    orch.handle({"t": "turn", "reason": "manual", "elapsed_sec": 102, "lines": [],
                 "agenda_manual": [], "notes": ""})
    assert len(submitted) == 2                       # но не поверх летящего


def test_timer_turn_merges():
    orch, _, submitted, clock = _orch()
    orch.handle(_turn())
    orch.on_result(orch.in_flight, _result())
    orch.handle({"t": "turn", "reason": "timer", "elapsed_sec": 300, "lines":
                 [{"ch": "them", "label": "И", "t0": 3, "t1": 4, "text": "время"}],
                 "agenda_manual": [], "notes": ""})
    clock.advance(2.5)
    orch.tick()
    assert len(submitted) == 2
    assert "Прошло 5 из 60 мин." in submitted[1].request.messages[-1]["content"]
    assert "время" in submitted[1].request.messages[-1]["content"]  # накопленное ушло


def test_rpm_limit_waits_and_emits_waiting():
    orch, events, submitted, clock = _orch(limits=Limits(rpm=6, debounce_sec=0))
    for i in range(7):
        orch.handle(_turn(lines=[{"ch": "them", "label": "И", "t0": i, "t1": i + 1,
                                  "text": f"фраза {i}"}]))
        if orch.in_flight is not None:
            orch.on_result(orch.in_flight, _result())
    assert len(submitted) == 6                       # седьмой ждёт
    waiting = [e for e in events if e["t"] == "waiting"]
    assert len(waiting) == 1                         # один раз на ожидание
    assert waiting[0]["reason"] == "rpm"
    assert waiting[0]["sec"] > 0
    clock.advance(waiting[0]["sec"])
    orch.tick()
    assert len(submitted) == 7


def test_cost_ceiling_pauses_and_finish_still_runs(tmp_path):
    orch, events, submitted, clock = _orch(tmp_path, limits=Limits(cost_ceiling_usd=0.05,
                                                                   debounce_sec=0))
    for i in range(2):
        orch.handle(_turn(lines=[{"ch": "them", "label": "И", "t0": i, "t1": i + 1,
                                  "text": f"фраза {i}"}]))
        orch.on_result(orch.in_flight, _result(usage=_usage_cost(0.03)))
    assert orch.cost_total == 0.06
    orch.handle(_turn(lines=[{"ch": "them", "label": "И", "t0": 3, "t1": 4, "text": "дальше"}]))
    assert any(e["t"] == "paused" and e["ceiling_usd"] == 0.05 for e in events)
    assert orch.paused_cost and len(submitted) == 2  # новые ходы не идут
    orch.handle({"t": "finish", "elapsed_sec": 600, "notes": "конец"})
    assert len(submitted) == 3                       # finish идёт и под потолком (D16)
    assert submitted[2].tag == "finish"
    orch.on_result(submitted[2], ProviderResult(
        text=FakeProvider.outcome_json(goal_result="partial"),
        usage=_usage_cost(0.01), ttft_ms=None, latency_ms=3000, format_used="json_schema"))
    outcomes = [e for e in events if e["t"] == "outcome"]
    assert outcomes[0]["ok"] is True
    assert (tmp_path / "outcome.json").exists()
    assert (tmp_path / "outcome.md").exists()


def _usage_cost(cost):
    from mlaud_worker.prompter.types import Usage
    return Usage(prompt_tokens=100, completion_tokens=10, cost_usd=cost)


def test_pause_command_drops_scheduled_turn_and_resume_fires():
    orch, _, submitted, clock = _orch()
    orch.handle(_turn())
    orch.on_result(orch.in_flight, _result())
    orch.handle({"t": "pause", "on": True})
    clock.advance(5)
    orch.tick()                                      # отложенный ход сброшен
    assert len(submitted) == 1
    orch.handle(_turn(lines=[{"ch": "them", "label": "И", "t0": 9, "t1": 10, "text": "тише"}]))
    assert len(submitted) == 1                       # на паузе только копится
    orch.handle({"t": "pause", "on": False})
    assert len(submitted) == 2                       # накопленное ушло по триггеру паузы


def test_cards_streamed_then_final_with_ids_and_only_changed_agenda(tmp_path):
    orch, events, submitted, _ = _orch(tmp_path)
    orch.handle(_turn())
    req = submitted[0]
    text = FakeProvider.cards_json(
        [{"type": "answer", "priority": 1, "text": "первая", "source": ""},
         {"type": "ask", "priority": 2, "text": "вторая", "source": "резюме.pdf"}],
        agenda=[{"item": "Кейс-задача", "status": "active"}], question_pending=True)
    for i in range(0, len(text), 7):
        orch.on_delta(req, text[i:i + 7])
    cards_streamed = [e for e in events if e["t"] == "card"]
    assert len(cards_streamed) == 2                  # обе карточки по мере закрытия
    assert cards_streamed[0]["card"]["id"] == "1.1"
    orch.on_result(req, _result(text=text))
    final = [e for e in events if e["t"] == "cards"][-1]
    assert [c["id"] for c in final["cards"]] == ["1.1", "1.2"]
    assert final["agenda"] == [{"item": "Кейс-задача", "status": "active"}]
    assert final["flags"]["question_pending"] is True
    assert final["first_card_ms"] is not None
    assert list(final["usage"].keys()) == ["prompt_tokens", "completion_tokens",
                                           "cached_tokens", "reasoning_tokens"]
    lines = (tmp_path / "cards.jsonl").read_text(encoding="utf-8").strip().split("\n")
    assert len(lines) == 4                           # 2 стрим + 2 финальных
    assert json.loads(lines[0])["card"]["id"] == "1.1"


def test_invalid_json_retries_once_then_reports_and_keeps_lines():
    orch, events, submitted, _ = _orch()
    orch.handle(_turn())
    bad = ProviderResult(text="{oops", usage=_usage_cost(0), ttft_ms=None,
                         latency_ms=100, format_used=None)
    orch.on_result(submitted[0], bad)                # первая неудача → повтор
    assert len(submitted) == 2
    assert "не разобран" in submitted[1].request.messages[-1]["content"]
    orch.on_result(submitted[1], bad)                # вторая → ход потерян
    errors = [e for e in events if e["t"] == "error"]
    assert errors and "не разобран" in errors[0]["message"]
    assert "retry_in_sec" not in errors[0]
    assert orch.history == []                        # user ушёл из истории
    assert orch.pending_lines                        # реплики в копилке
    orch.handle({"t": "turn", "reason": "manual", "elapsed_sec": 110,
                 "lines": [{"ch": "them", "label": "И", "t0": 9, "t1": 10, "text": "заново"}],
                 "agenda_manual": [], "notes": ""})
    assert len(submitted) == 3
    content = submitted[2].request.messages[-1]["content"]
    assert "вопрос" in content and "заново" in content   # восстановленное + новое в одном ходе


def test_network_error_backoff_and_recovery():
    orch, events, submitted, clock = _orch()
    orch.handle(_turn())
    orch.on_error(submitted[0], ProviderError("5xx", retry_in_sec=10))
    error = [e for e in events if e["t"] == "error"][-1]
    assert error["retry_in_sec"] == 10
    assert orch.next_deadline() == clock.t + 10
    clock.advance(10)
    orch.tick()
    assert len(submitted) == 2                       # повтор тем же сообщением
    assert submitted[1].request.messages[-1] == submitted[0].request.messages[-1]
    orch.on_result(submitted[1], _result())
    assert any(e["t"] == "cards" for e in events)


def test_fatal_error_disables_and_finish_reports_not_ok():
    orch, events, submitted, _ = _orch()
    orch.handle(_turn())
    orch.on_error(submitted[0], ProviderError("ключ отвергнут", fatal=True))
    assert orch.disabled
    assert any(e["t"] == "error" and e.get("fatal") for e in events)
    orch.handle({"t": "finish", "elapsed_sec": 60, "notes": ""})
    outcome = [e for e in events if e["t"] == "outcome"][-1]
    assert outcome["ok"] is False


def test_warm_on_begin_and_repeat_until_first_turn():
    orch, events, submitted, clock = _orch(limits=Limits(warm_every_sec=240))
    orch.begin()
    assert submitted[0].tag == "warm" and submitted[0].request.max_tokens == 1
    assert submitted[0].request.schema is None
    orch.on_result(submitted[0], ProviderResult(text="Готов.", usage=_usage_cost(0),
                                                ttft_ms=800, latency_ms=900, format_used=None))
    assert events[0]["t"] == "warm" and events[0]["ok"] is True
    clock.advance(240)
    orch.tick()                                      # повтор прогрева до первого хода
    assert submitted[1].tag == "warm"
    orch.on_result(submitted[1], ProviderResult(text="Готов.", usage=_usage_cost(0),
                                                ttft_ms=700, latency_ms=800, format_used=None))
    orch.handle(_turn())
    orch.on_result(orch.in_flight, _result())
    clock.advance(600)
    orch.tick()
    assert all(r.tag != "warm" for r in submitted[2:])   # после первого хода прогрева нет


def test_detail_not_in_history_and_queued_behind_flight():
    orch, events, submitted, _ = _orch()
    orch.handle(_turn())
    orch.on_result(orch.in_flight, _result())
    history_len = len(orch.history)
    orch.handle({"t": "detail", "card_id": "1.1"})
    detail_req = submitted[-1]
    assert detail_req.tag == "detail"
    assert len(orch.history) == history_len          # в историю не попал
    orch.handle({"t": "turn", "reason": "manual", "elapsed_sec": 10,
                 "lines": [{"ch": "them", "label": "И", "t0": 1, "t1": 2, "text": "новое"}],
                 "agenda_manual": [], "notes": ""})
    turn_after_detail = [r for r in submitted if r.tag == "turn"]
    assert len(turn_after_detail) == 1               # ход не стартует поверх detail
    orch.on_result(detail_req, ProviderResult(
        text='{"text": "раскрытие"}', usage=_usage_cost(0), ttft_ms=None, latency_ms=100,
        format_used=None))
    detail_event = [e for e in events if e["t"] == "detail"]
    assert detail_event[-1]["card_id"] == "1.1"
    assert detail_event[-1]["text"] == "раскрытие"


def test_finish_waits_for_flight_writes_outcome_files(tmp_path):
    (tmp_path / "call.json").write_text(json.dumps(
        {"version": 1, "call_id": "c-1", "brief": "Интервью", "started_at": "2026-09-05T12:00:00+03:00"}),
        encoding="utf-8")
    orch, events, submitted, _ = _orch(tmp_path, has_criteria=True)
    orch.handle(_turn())
    orch.handle({"t": "finish", "elapsed_sec": 600, "notes": "итог"})
    assert [r.tag for r in submitted] == ["turn"]    # finish ждёт
    orch.on_result(submitted[0], _result())
    assert submitted[1].tag == "finish"
    assert "критери" in submitted[1].request.messages[-1]["content"]   # has_criteria попал
    orch.on_result(submitted[1], ProviderResult(
        text=FakeProvider.outcome_json(goal_result="achieved", reason="ок",
                                       assessment=[{"criterion": "опыт", "verdict": "да",
                                                    "evidence": "цитата"}]),
        usage=_usage_cost(0.001), ttft_ms=None, latency_ms=4000, format_used="json_schema"))
    outcome = [e for e in events if e["t"] == "outcome"][-1]
    assert outcome["ok"] is True
    assert outcome["outcome"]["goal_result"] == "achieved"
    assert outcome["path"] == str(tmp_path / "outcome.md")
    saved = json.loads((tmp_path / "outcome.json").read_text(encoding="utf-8"))
    assert saved["call_id"] == "c-1" and saved["version"] == 1
    md = (tmp_path / "outcome.md").read_text(encoding="utf-8")
    assert "Интервью" in md and "| опыт | да | цитата |" in md
    log = (tmp_path / "prompter.log.jsonl").read_text(encoding="utf-8").strip().split("\n")
    assert any(json.loads(row)["tag"] == "finish" for row in log)


def test_unknown_shown_card_detail_is_noop():
    orch, _, submitted, _ = _orch()
    orch.handle(_turn())
    orch.on_result(orch.in_flight, _result())
    orch.handle({"t": "detail", "card_id": "нет-такой"})
    assert [r.tag for r in submitted] == ["turn"]    # запроса не было


def test_lost_turn_streak_is_capped():
    """Модель всегда отдаёт не-JSON: три потерянных хода подряд — фатальная ошибка,
    дальше запросов нет, сколько бы реплик ни приходило (цикл «ход-повтор-потеря»
    жёг запросы без предела)."""
    orch, events, submitted, _ = _orch()
    bad = ProviderResult(text="{oops", usage=_usage_cost(0), ttft_ms=None,
                         latency_ms=100, format_used=None)
    for round_ in range(3):
        orch.handle(_turn(msg_t="manual",
                          lines=[{"ch": "them", "label": "И", "t0": round_, "t1": round_ + 1,
                                  "text": f"вопрос {round_}"}]))
        orch.on_result(submitted[-1], bad)          # повтор тем же сообщением
        orch.on_result(submitted[-1], bad)          # потеря хода
    fatal = [e for e in events if e.get("fatal")]
    assert fatal and "три хода подряд" in fatal[-1]["message"]
    assert len(submitted) == 6                      # 3 хода × (ход + один повтор)
    n = len(submitted)
    orch.handle(_turn(msg_t="manual",
                      lines=[{"ch": "them", "label": "И", "t0": 9, "t1": 10, "text": "ещё"}]))
    assert len(submitted) == n, "после фатала запросов нет"
