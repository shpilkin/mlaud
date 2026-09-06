"""Схемы ответов модели (feature-prompter.md §7.3) и их нормализация без библиотеки jsonschema."""

CARD_TYPES = ["answer", "ask", "fact", "next_step", "off_route", "tension", "time"]
AGENDA_STATUS = ["pending", "active", "done"]
GOAL_RESULT = ["achieved", "partial", "not"]
MAX_CARDS = 3

CARDS_SCHEMA = {
    "type": "object",
    "properties": {
        "cards": {"type": "array", "maxItems": MAX_CARDS, "items": {
            "type": "object",
            "properties": {"type": {"type": "string", "enum": CARD_TYPES},
                           "priority": {"type": "integer"},
                           "text": {"type": "string"},
                           "source": {"type": "string"}},
            "required": ["type", "priority", "text", "source"], "additionalProperties": False}},
        "agenda": {"type": "array", "items": {
            "type": "object",
            "properties": {"item": {"type": "string"}, "status": {"type": "string", "enum": AGENDA_STATUS}},
            "required": ["item", "status"], "additionalProperties": False}},
        "flags": {"type": "object", "properties": {"question_pending": {"type": "boolean"}},
                  "required": ["question_pending"], "additionalProperties": False}},
    "required": ["cards", "agenda", "flags"], "additionalProperties": False}

_STRING_LIST = {"type": "array", "items": {"type": "string"}}

OUTCOME_SCHEMA = {
    "type": "object",
    "properties": {
        "goal_result": {"type": "string", "enum": GOAL_RESULT},
        "reason": {"type": "string"},
        "summary": {"type": "string"},
        "decisions": _STRING_LIST,
        "next_steps": _STRING_LIST,
        "open_questions": _STRING_LIST,
        "assessment": {"type": "array", "items": {
            "type": "object",
            "properties": {"criterion": {"type": "string"}, "verdict": {"type": "string"},
                           "evidence": {"type": "string"}},
            "required": ["criterion", "verdict", "evidence"], "additionalProperties": False}}},
    "required": ["goal_result", "reason", "summary", "decisions", "next_steps", "open_questions", "assessment"],
    "additionalProperties": False}

DETAIL_SCHEMA = {"type": "object", "properties": {"text": {"type": "string"}},
                 "required": ["text"], "additionalProperties": False}


def _as_int(value, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _as_str(value) -> str:
    if value is None:
        return ""
    return value if isinstance(value, str) else str(value)


def _str_list(value) -> list:
    if not isinstance(value, list):
        return []
    return [_as_str(x) for x in value if x is not None]


def validate_cards(data) -> dict:
    """Нормализация ответа хода. Сначала выбрасываются карточки с неизвестным type, потом
    остаток срезается до MAX_CARDS; text → str, priority → int; нет cards/agenda/flags → ValueError."""
    if not isinstance(data, dict):
        raise ValueError("ответ не объект")
    for key in ("cards", "agenda", "flags"):
        if key not in data:
            raise ValueError(f"нет поля {key}")
    raw_cards = data["cards"]
    if not isinstance(raw_cards, list):
        raise ValueError("cards не массив")
    cards = []
    for card in raw_cards:
        if not isinstance(card, dict) or card.get("type") not in CARD_TYPES:
            continue
        cards.append({
            "type": card["type"],
            "priority": _as_int(card.get("priority")),
            "text": _as_str(card.get("text")),
            "source": _as_str(card.get("source")),
        })
    cards = cards[:MAX_CARDS]
    agenda = []
    raw_agenda = data["agenda"] if isinstance(data["agenda"], list) else []
    for entry in raw_agenda:
        if not isinstance(entry, dict) or entry.get("status") not in AGENDA_STATUS:
            continue
        item = _as_str(entry.get("item"))
        if not item:
            continue
        agenda.append({"item": item, "status": entry["status"]})
    flags = data["flags"] if isinstance(data["flags"], dict) else {}
    return {
        "cards": cards,
        "agenda": agenda,
        "flags": {"question_pending": bool(flags.get("question_pending", False))},
    }


def validate_outcome(data) -> dict:
    """goal_result вне enum → ValueError; строки → str, списки по умолчанию []."""
    if not isinstance(data, dict):
        raise ValueError("итоги не объект")
    goal = data.get("goal_result")
    if goal not in GOAL_RESULT:
        raise ValueError(f"goal_result вне допустимых: {goal!r}")
    assessment = []
    raw_assessment = data.get("assessment")
    if isinstance(raw_assessment, list):
        for row in raw_assessment:
            if not isinstance(row, dict):
                continue
            assessment.append({
                "criterion": _as_str(row.get("criterion")),
                "verdict": _as_str(row.get("verdict")),
                "evidence": _as_str(row.get("evidence")),
            })
    return {
        "goal_result": goal,
        "reason": _as_str(data.get("reason")),
        "summary": _as_str(data.get("summary")),
        "decisions": _str_list(data.get("decisions")),
        "next_steps": _str_list(data.get("next_steps")),
        "open_questions": _str_list(data.get("open_questions")),
        "assessment": assessment,
    }
