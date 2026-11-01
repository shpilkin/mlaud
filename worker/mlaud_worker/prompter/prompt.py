"""Сборка промтов подсказчика (feature-prompter.md §7.2): стабильный префикс первым —
ROLE → профиль → бриф → дополнение шаблона → материалы → схема ответа; ход — новым
user-сообщением. Детерминированно: снимок prompt/system.golden.txt."""

import json

from .brief import Brief
from .materials import estimate_tokens
from .schema import CARDS_SCHEMA

# Отправная точка — INSTRUCTIONS из poc/prompter-latency/run.py:89-106, приведённые к
# контракту §7.3 (S5: ≤3 карточек и ≤100 символов режут полный ответ с 7.7 до 5.7 с).
ROLE = """Ты — суфлёр в живом деловом разговоре. Ты помогаешь ПОЛЬЗОВАТЕЛЮ (реплики «Я»), \
пока он говорит с собеседником, и работаешь в реальном времени.

На каждый ход приходят новые реплики с момента прошлого хода и прошедшее время. Верни \
JSON строго по схеме ответа — без текста вокруг.

Правила карточек:
- text — не длиннее 100 символов, по-русски, читается одним взглядом; source — имя \
материала, если факт взят из материалов, иначе "".
- Не больше 3 карточек за ход, самое важное — priority 1. Подсказывать нечего — пустой список.
- Не повторяй карточки, которые уже показывал: вся история беседы видна тебе, пока \
ситуация не изменилась.
- Типы: answer — что ответить на вопрос собеседника; ask — что спросить; fact — факт или \
цифра из материалов; next_step — следующий шаг по маршруту; off_route — ушли с повестки; \
tension — напряжение или возражение и как сгладить; time — про время и повестку.
- agenda — ТОЛЬКО пункты, чьё состояние изменилось с прошлого хода (пусто — ничего не менялось).
- flags.question_pending — собеседник задал вопрос, на который «Я» ещё не ответил."""

STATUS_LABELS = {"pending": "ждёт", "active": "идёт", "done": "закрыт"}


def system_prompt(*, profile: str, brief: Brief, addendum: str, materials: list) -> str:
    """FP:495-497. Пустой профиль → раздел пропущен; порядок материалов — по возрастанию
    tokens (передают отсортированным), самое большое последним."""
    from .brief import render
    parts = [ROLE]
    if profile.strip():
        parts.append("=== ПРОФИЛЬ ===\n" + profile.strip())
    parts.append("=== БРИФ ===\n" + render(brief))
    if addendum.strip():
        parts.append("=== ДОПОЛНЕНИЕ ШАБЛОНА ===\n" + addendum.strip())
    if materials:
        blocks = [f"--- {m.name} ---\n{m.text}" for m in materials]
        parts.append("=== МАТЕРИАЛЫ ===\n" + "\n\n".join(blocks))
    parts.append("=== СХЕМА ОТВЕТА ===\n" + json.dumps(CARDS_SCHEMA, ensure_ascii=False))
    return "\n\n".join(parts)


def _minutes(sec: int) -> int:
    return int(sec // 60)


def turn_message(*, elapsed_sec: int, expected_min: int, lines: list, agenda_manual: list, notes: str) -> str:
    """Новые реплики с момента прошлого хода; пусто → «(тишина)»."""
    if lines:
        rows = [f"{l.get('label', '?')}: {l.get('text', '')}".strip() for l in lines]
        dialogue = "\n".join(rows)
    else:
        dialogue = "(тишина)"
    parts = [f"Прошло {_minutes(elapsed_sec)} из {expected_min} мин.\nНовые реплики:\n{dialogue}"]
    if agenda_manual:
        rows = [f"- {a['item']} → {STATUS_LABELS.get(a['status'], a['status'])}" for a in agenda_manual]
        parts.append("Повестка вручную:\n" + "\n".join(rows))
    if notes.strip():
        parts.append(f"Заметки:\n{notes.strip()}")
    parts.append("Дай подсказки для «Я» по правилам и схеме.")
    return "\n\n".join(parts)


def finish_message(*, elapsed_sec: int, expected_min: int, lines: list, notes: str, has_criteria: bool) -> str:
    """Ход итогов: вся накопленная беседа уже в истории; линии — последние с прошлого хода."""
    parts = [f"Звонок окончен: прошло {_minutes(elapsed_sec)} из {expected_min} мин."]
    if lines:
        rows = [f"{l.get('label', '?')}: {l.get('text', '')}".strip() for l in lines]
        parts.append("Последние реплики:\n" + "\n".join(rows))
    if notes.strip():
        parts.append(f"Заметки пользователя:\n{notes.strip()}")
    if has_criteria:
        parts.append("У шаблона есть критерии: заполни assessment по каждому критерию с цитатой-основанием.")
    parts.append("Дай итоги звонка по схеме итогов.")
    return "\n\n".join(parts)


def detail_message(card: dict) -> str:
    return (f"Раскрой карточку «{card.get('text', '')}» (тип {card.get('type', '?')}): "
            f"2–4 предложения с конкретикой. Верни JSON {{\"text\": …}}.")


def warm_message() -> str:
    return "Готов."


def context_tokens(system: str) -> int:
    return estimate_tokens(system)
