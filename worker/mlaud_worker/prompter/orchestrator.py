"""Машина хода подсказчика: дебаунс, лимиты, повторы, история (stage4-brief §4.3, FP:540-547,
FR-12.14). Без потоков и сети: обмены — через `submit`, время — через `clock`."""

import json
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

from . import prompt
from .jsonstream import CardStream, split_reply
from .schema import CARDS_SCHEMA, DETAIL_SCHEMA, OUTCOME_SCHEMA, validate_cards, validate_outcome
from .types import Connection, Limits, ProviderError, ProviderResult, TurnRequest

REASON_PRIORITY = {"timer": 0, "them_phrase": 1, "manual": 2}
MAX_ATTEMPTS = 3
MAX_LOST_TURNS = 3


@dataclass(frozen=True)
class Request:
    id: int
    tag: str                     # "warm" | "turn" | "detail" | "finish"
    turn: Optional[int]
    request: TurnRequest


@dataclass
class _TurnState:
    """Что ушло в последний ход — для отката при неудаче (§4.3)."""
    lines: list
    agenda: list
    notes: str
    elapsed: int


class Orchestrator:
    def __init__(self, *, emit: Callable[[dict], None], submit: Callable[[Request], None],
                 clock: Callable[[], float], limits: Limits, connection: Connection,
                 system_prompt: str, expected_min: int, call_dir: Optional[Path] = None,
                 now_iso: Callable[[], str] = lambda: datetime.now().astimezone().isoformat(timespec="seconds"),
                 messages_builder=prompt, has_criteria: bool = False) -> None:
        self.emit = emit
        self.submit = submit
        self.clock = clock
        self.limits = limits
        self.connection = connection
        self.system_prompt = system_prompt
        self.expected_min = expected_min
        self.call_dir = call_dir
        self.now_iso = now_iso
        self.messages = messages_builder
        self.has_criteria = has_criteria
        # Состояние (для тестов).
        self.in_flight: Optional[Request] = None
        self._lost_streak = 0              # проигранные ходы подряд; 3 — модель не отвечает форматом
        self.pending_lines: list = []
        self.pending_reason: Optional[str] = None
        self.pending_agenda: list = []
        self.notes = ""
        self.elapsed = 0
        self.history: list = []
        self.turn_no = 0
        self.cost_total = 0.0
        self.request_times: deque = deque()
        self.paused_user = False
        self.paused_cost = False
        self.disabled = False
        self.finishing = False
        self.shown_cards: list = []
        self.attempt = 0
        self._request_seq = 0
        self._last_state: Optional[_TurnState] = None
        self._retry_at: Optional[float] = None
        self._debounce_at: Optional[float] = None
        self._rpm_at: Optional[float] = None
        self._waiting_emitted = False
        self._last_start = float("-inf")
        self._warm_at: Optional[float] = None
        self._stream: Optional[CardStream] = None
        self._stream_cards = 0
        self._fired_at: float = 0.0
        self._first_card_ms: Optional[int] = None
        self._pending_detail: Optional[str] = None
        self._detail_card_id: Optional[str] = None
        self._pending_finish = False
        self._json_retry_turn: Optional[int] = None

    # ---- журнал и события

    def _log(self, **row) -> None:
        if self.call_dir is None:
            return
        row.setdefault("at", self.now_iso())
        with open(self.call_dir / "prompter.log.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    def _card_line(self, turn, card: dict) -> None:
        if self.call_dir is None:
            return
        row = {"turn": turn, "elapsed_sec": self.elapsed, "at": self.now_iso(), "card": card}
        with open(self.call_dir / "cards.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    def _next_id(self) -> int:
        self._request_seq += 1
        return self._request_seq

    def _system_messages(self, tail: list) -> list:
        return [{"role": "system", "content": self.system_prompt}] + tail

    # ---- команды (start обрабатывает __main__)

    def handle(self, msg: dict) -> None:
        kind = msg.get("t")
        if kind == "turn":
            self.pending_lines += msg.get("lines") or []
            reason = msg.get("reason", "them_phrase")
            if REASON_PRIORITY.get(reason, 0) >= REASON_PRIORITY.get(self.pending_reason, 0):
                self.pending_reason = reason
            self.pending_agenda += msg.get("agenda_manual") or []
            self.notes = msg.get("notes", "")
            self.elapsed = msg.get("elapsed_sec", self.elapsed)
            self._maybe_fire()
        elif kind == "pause":
            if msg.get("on"):
                self.paused_user = True
                self._debounce_at = None
                self._rpm_at = None
            else:
                self.paused_user = False
                self._maybe_fire()
        elif kind == "detail":
            self._pending_detail = msg.get("card_id", "")
            self._maybe_detail()
        elif kind == "finish":
            self.finishing = True
            self._pending_finish = True
            self.notes = msg.get("notes", self.notes)
            self.elapsed = msg.get("elapsed_sec", self.elapsed)
            self._maybe_finish()
        elif kind == "quit":
            return

    # ---- стрельба ходами

    def _maybe_fire(self) -> None:
        if self.disabled or self.paused_user or self.paused_cost or self.finishing:
            return
        if self._lost_streak >= MAX_LOST_TURNS:
            return
        if self.in_flight is not None:
            return
        if not self.pending_reason:
            return
        if not self.pending_lines and self.pending_reason != "manual":
            return                      # без реплик ход не стартует, кроме ручного (D18)
        if self.pending_reason != "manual" and self.clock() < self._last_start + self.limits.debounce_sec:
            self._debounce_at = self._last_start + self.limits.debounce_sec
            return
        window = [t for t in self.request_times if self.clock() - t < 60]
        if len(window) >= self.limits.rpm:
            self._rpm_at = window[0] + 60
            if not self._waiting_emitted:
                self.emit({"t": "waiting", "reason": "rpm", "sec": int(self._rpm_at - self.clock())})
                self._waiting_emitted = True
            return
        ceiling = self.limits.cost_ceiling_usd
        if ceiling is not None and self.cost_total >= ceiling:
            self.paused_cost = True
            self.emit({"t": "paused", "reason": "cost_ceiling",
                       "cost_usd": round(self.cost_total, 6), "ceiling_usd": ceiling})
            return
        self._fire()

    def _fire(self) -> None:
        self.turn_no += 1
        state = _TurnState(lines=self.pending_lines, agenda=self.pending_agenda,
                           notes=self.notes, elapsed=self.elapsed)
        content = self.messages.turn_message(
            elapsed_sec=state.elapsed, expected_min=self.expected_min,
            lines=state.lines, agenda_manual=state.agenda, notes=state.notes)
        self.history.append({"role": "user", "content": content})
        self.pending_lines = []
        self.pending_agenda = []
        self.pending_reason = None
        self._last_state = state
        self._last_start = self.clock()
        self.request_times.append(self._last_start)
        self._waiting_emitted = False
        self._debounce_at = None
        self._rpm_at = None
        self._begin_stream()
        self.in_flight = Request(
            id=self._next_id(), tag="turn", turn=self.turn_no,
            request=TurnRequest(messages=self._system_messages(self.history), schema=CARDS_SCHEMA,
                                tag="turn"))
        self.submit(self.in_flight)

    def _begin_stream(self) -> None:
        self._stream = CardStream()
        self._stream_cards = 0
        self._fired_at = self.clock()
        self._first_card_ms = None

    def _retry(self) -> None:
        """Повтор неудачного хода тем же сообщением; накопившиеся реплики — в него же."""
        self._retry_at = None
        state = self._last_state
        merged = state.lines + self.pending_lines
        content = self.messages.turn_message(
            elapsed_sec=self.elapsed, expected_min=self.expected_min, lines=merged,
            agenda_manual=state.agenda, notes=self.notes)
        self.history[-1] = {"role": "user", "content": content}
        state.lines = merged
        self.pending_lines = []
        self.pending_reason = None
        self._begin_stream()
        self.in_flight = Request(
            id=self._next_id(), tag="turn", turn=self.turn_no,
            request=TurnRequest(messages=self._system_messages(self.history), schema=CARDS_SCHEMA,
                                tag="turn"))
        self.submit(self.in_flight)

    def _lose_turn(self, message: str) -> None:
        """Ход потерян: user уходит из истории, реплики возвращаются в копилку (§4.3).
        Три подряд потерянных — модель детерминированно битая (не-JSON и т.п.):
        фатальная ошибка, иначе цикл «ход-повтор-потеря» жжёт запросы без предела."""
        if self.history and self.history[-1]["role"] == "user":
            self.history.pop()
        if self._last_state is not None:
            self.pending_lines = self._last_state.lines + self.pending_lines
            if self.pending_reason is None:
                self.pending_reason = "them_phrase"
        self.attempt = 0
        self._lost_streak += 1
        if self._lost_streak >= MAX_LOST_TURNS:
            self.pending_lines = []
            self.pending_reason = None
            self.emit({"t": "error", "message": f"три хода подряд потеряны ({message}) — "
                                                "модель не отвечает форматом, суфлёр выключен",
                       "fatal": True})
            self._log(tag="turn", turn=self.turn_no, error=f"lost streak {self._lost_streak}")
            return
        event = {"t": "error", "message": message}
        if self.turn_no:
            event["turn"] = self.turn_no
        self.emit(event)

    # ---- ответы провайдера

    def on_result(self, req: Request, result: ProviderResult) -> None:
        if req.tag == "warm":
            self.emit({"t": "warm", "ok": True, "ttft_ms": result.ttft_ms,
                       "usage": result.usage.to_json()})
            self._log(tag="warm", turn=None, status=result.status_code, ttft_ms=result.ttft_ms,
                      latency_ms=result.latency_ms, usage=result.usage.to_json(),
                      cost_usd=result.usage.cost_usd, format=result.format_used, error=None)
            if self.turn_no == 0:
                self._warm_at = self.clock() + self.limits.warm_every_sec
            self._after_flight(req)
            return
        if req.tag == "detail":
            try:
                data, _, _ = split_reply(result.text)
                detail_text = data.get("text", result.text)
            except ValueError:
                detail_text = result.text
            self.emit({"t": "detail", "card_id": self._detail_card_id or "",
                       "text": detail_text})
            self._detail_card_id = None
            self._log(tag="detail", turn=req.turn, status=result.status_code,
                      latency_ms=result.latency_ms, error=None)
            self._after_flight(req)
            return
        if req.tag == "finish":
            self._finish_result(req, result)
            return
        self._turn_result(req, result)

    def _turn_result(self, req: Request, result: ProviderResult) -> None:
        from .providers import estimate_cost
        cost = estimate_cost(result.usage, self.connection)
        if cost is not None:
            self.cost_total += cost
        try:
            payload, json_text = self._parse_cards(result.text)
        except ValueError:
            if self._json_retry_turn != req.turn:
                self._json_retry_turn = req.turn
                self._retry_json(req)
                return
            self._json_retry_turn = None
            self._lose_turn("ответ не разобран")
            self._log(tag="turn", turn=req.turn, status=result.status_code, error="bad json")
            self._after_flight(req, lose=True)
            return
        self._json_retry_turn = None
        self.history.append({"role": "assistant", "content": json_text})
        cards = payload["cards"]
        for i, card in enumerate(cards):
            card["id"] = f"{req.turn}.{i + 1}"
        self.shown_cards = cards
        self._lost_streak = 0
        self.emit({"t": "cards", "turn": req.turn, "cards": cards, "agenda": payload["agenda"],
                   "flags": payload["flags"], "usage": result.usage.to_json(),
                   "first_card_ms": self._first_card_ms, "latency_ms": result.latency_ms,
                   "cost_usd": cost, "cost_total_usd": round(self.cost_total, 6)})
        for card in cards:
            self._card_line(req.turn, card)
        self.attempt = 0
        self._log(tag="turn", turn=req.turn, status=result.status_code, ttft_ms=result.ttft_ms,
                  latency_ms=result.latency_ms, usage=result.usage.to_json(),
                  cost_usd=cost, format=result.format_used, error=None)
        self._after_flight(req)

    @staticmethod
    def _parse_cards(text: str):
        data, json_text, _ = split_reply(text)
        return validate_cards(data), json_text

    def _retry_json(self, req: Request) -> None:
        """Тот же user + «Ответ не разобран…» во временной копии; история не мутирует."""
        messages = [dict(m) for m in req.request.messages]
        for i in range(len(messages) - 1, -1, -1):
            if messages[i].get("role") == "user":
                messages[i] = dict(messages[i])
                messages[i]["content"] += "\n\nОтвет не разобран: верни только JSON по схеме."
                break
        self._begin_stream()
        self.in_flight = Request(id=self._next_id(), tag="turn", turn=req.turn,
                                 request=TurnRequest(messages=messages, schema=CARDS_SCHEMA,
                                                     tag="turn"))
        self.submit(self.in_flight)

    def on_error(self, req: Request, error: ProviderError) -> None:
        if req.tag == "warm":
            self.emit({"t": "warm", "ok": False, "message": error.message})
            if error.fatal:
                self.disabled = True
            self._log(tag="warm", turn=None, error=error.message)
            self._after_flight(req)
            return
        if req.tag == "detail":
            self.emit({"t": "error", "message": error.message, "turn": req.turn})
            self._detail_card_id = None
            self._log(tag="detail", turn=req.turn, error=error.message)
            self._after_flight(req)
            return
        if req.tag == "finish":
            self.emit({"t": "outcome", "ok": False, "message": error.message,
                       "cost_total_usd": round(self.cost_total, 6)})
            self._log(tag="finish", turn=None, error=error.message)
            self._after_flight(req)
            return
        if error.fatal:
            self.disabled = True
            if self.history and self.history[-1]["role"] == "user":
                self.history.pop()
            self.emit({"t": "error", "message": error.message, "fatal": True})
            self._log(tag="turn", turn=req.turn, error=error.message)
            self._after_flight(req)
            return
        self.attempt += 1
        if self.attempt >= MAX_ATTEMPTS:
            self._lose_turn(error.message)
            self._log(tag="turn", turn=req.turn, error=error.message)
            self._after_flight(req, lose=True)
            return
        backoff = min(60, 5 * 2 ** (self.attempt - 1))
        if error.retry_in_sec is not None and error.retry_in_sec > backoff:
            backoff = error.retry_in_sec
        self.emit({"t": "error", "message": error.message, "retry_in_sec": backoff, "turn": req.turn})
        self._retry_at = self.clock() + backoff
        if self.in_flight is not None and self.in_flight.id == req.id:
            self.in_flight = None          # обмен завершён ошибкой; повтор — по _retry_at
        self._log(tag="turn", turn=req.turn, error=error.message)

    def _after_flight(self, req: Request, *, lose: bool = False) -> None:
        if self.in_flight is not None and self.in_flight.id == req.id:
            self.in_flight = None
        if self._pending_detail:
            self._maybe_detail()
        elif self._pending_finish:
            self._maybe_finish()
        elif lose or self.in_flight is None:
            self._maybe_fire()

    # ---- стрим

    def on_delta(self, req: Request, delta: str) -> None:
        if req.tag != "turn" or self._stream is None:
            return
        for card in self._stream.feed(delta):
            self._stream_cards += 1
            card["id"] = f"{req.turn}.{self._stream_cards}"
            if self._first_card_ms is None:
                self._first_card_ms = int((self.clock() - self._fired_at) * 1000)
            self.emit({"t": "card", "turn": req.turn, "card": card})
            self._card_line(req.turn, card)

    # ---- прогрев

    def begin(self) -> None:
        """После ready: первый прогрев (FP:508-510)."""
        self._warm_now()

    def _warm_now(self) -> None:
        if self.in_flight is not None or self.disabled:
            self._warm_at = self.clock() + 1     # занято — попробовать снова
            return
        req = Request(id=self._next_id(), tag="warm", turn=None,
                      request=TurnRequest(messages=self._system_messages(
                          [{"role": "user", "content": self.messages.warm_message()}]),
                          max_tokens=1, schema=None, tag="warm"))
        self.in_flight = req
        self.submit(req)

    # ---- detail и finish

    def _maybe_detail(self) -> None:
        card_id = self._pending_detail
        if not card_id or self.in_flight is not None:
            return
        card = next((c for c in self.shown_cards if c.get("id") == card_id), None)
        self._pending_detail = None
        if card is None:
            return
        # Побочный запрос: в историю не попадает (D8 — стабильный префикс и кэш).
        self._detail_card_id = card_id
        messages = self._system_messages(
            self.history + [{"role": "user", "content": self.messages.detail_message(card)}])
        self.in_flight = Request(id=self._next_id(), tag="detail", turn=self.turn_no,
                                 request=TurnRequest(messages=messages, schema=DETAIL_SCHEMA,
                                                     tag="detail"))
        self.submit(self.in_flight)

    def _maybe_finish(self) -> None:
        if not self._pending_finish or self.in_flight is not None:
            return
        self._pending_finish = False
        if self.disabled:
            self.emit({"t": "outcome", "ok": False, "message": "суфлёр выключен",
                       "cost_total_usd": round(self.cost_total, 6)})
            return
        # Итоги идут даже под потолком стоимости — явное действие пользователя (D16).
        content = self.messages.finish_message(
            elapsed_sec=self.elapsed, expected_min=self.expected_min, lines=self.pending_lines,
            notes=self.notes, has_criteria=self.has_criteria)
        self.pending_lines = []
        self.pending_reason = None
        messages = self._system_messages(self.history + [{"role": "user", "content": content}])
        self.in_flight = Request(id=self._next_id(), tag="finish", turn=None,
                                 request=TurnRequest(messages=messages, schema=OUTCOME_SCHEMA,
                                                     max_tokens=2000, tag="finish"))
        self.submit(self.in_flight)

    def _finish_result(self, req: Request, result: ProviderResult) -> None:
        from .outcome import render_markdown
        from .providers import estimate_cost
        cost = estimate_cost(result.usage, self.connection)
        if cost is not None:
            self.cost_total += cost
        try:
            data, _, _ = split_reply(result.text)
            payload = validate_outcome(data)
        except ValueError:
            self.emit({"t": "outcome", "ok": False, "message": "итоги не разобраны",
                       "cost_total_usd": round(self.cost_total, 6)})
            self._log(tag="finish", turn=None, error="bad json")
            self._after_flight(req)
            return
        title, call_id, started_at = self._call_meta()
        outcome_path = None
        if self.call_dir is not None:
            self.call_dir.mkdir(parents=True, exist_ok=True)
            (self.call_dir / "outcome.json").write_text(json.dumps({
                "version": 1, "call_id": call_id, "outcome": payload,
                "usage": result.usage.to_json(), "cost_total_usd": round(self.cost_total, 6),
                "created_at": self.now_iso()}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            outcome_path = self.call_dir / "outcome.md"
            outcome_path.write_text(render_markdown(payload, title=title, call_id=call_id,
                                                    started_at=started_at, notes=[]), encoding="utf-8")
        self.emit({"t": "outcome", "ok": True, "outcome": payload, "usage": result.usage.to_json(),
                   "latency_ms": result.latency_ms, "cost_usd": cost,
                   "cost_total_usd": round(self.cost_total, 6),
                   "path": str(outcome_path) if outcome_path else None})
        self._log(tag="finish", turn=None, status=result.status_code,
                  latency_ms=result.latency_ms, usage=result.usage.to_json(), cost_usd=cost, error=None)
        self._after_flight(req)

    def _call_meta(self):
        title, call_id, started_at = "Звонок", "", ""
        meta = {}
        if self.call_dir is not None:
            meta_path = self.call_dir / "call.json"
            if meta_path.exists():
                try:
                    meta = json.loads(meta_path.read_text(encoding="utf-8"))
                except ValueError:
                    meta = {}
            call_id = meta.get("call_id", "")
            started_at = meta.get("started_at", "")
            title = meta.get("brief") or call_id or "Звонок"
        return title, call_id, started_at

    # ---- таймеры

    def next_deadline(self) -> Optional[float]:
        deadlines = [d for d in (self._debounce_at, self._rpm_at, self._retry_at, self._warm_at)
                     if d is not None]
        return min(deadlines) if deadlines else None

    def tick(self) -> None:
        now = self.clock()
        if self._retry_at is not None and now >= self._retry_at and self.in_flight is None:
            self._retry()
            return
        if (self._warm_at is not None and now >= self._warm_at and self.turn_no == 0
                and not self.paused_user and self.in_flight is None and not self.disabled):
            self._warm_at = None
            self._warm_now()
            return
        if ((self._debounce_at is not None and now >= self._debounce_at)
                or (self._rpm_at is not None and now >= self._rpm_at)):
            self._debounce_at = None
            self._rpm_at = None
            self._waiting_emitted = False
            self._maybe_fire()
