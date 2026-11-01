"""Тесты P1: сборка промтов — снимок системного, сообщения хода/итогов/раскрытия."""

from pathlib import Path

from mlaud_worker.prompter import prompt
from mlaud_worker.prompter.brief import parse_brief
from mlaud_worker.prompter.materials import Material
from mlaud_worker.prompter.prompt import (context_tokens, detail_message, finish_message,
                                          system_prompt, turn_message, warm_message)

FIXTURES = Path(__file__).parent / "fixtures"
GOLDEN = FIXTURES / "prompt" / "system.golden.txt"


def _golden_brief():
    return parse_brief((FIXTURES / "brief" / "ok-full.md").read_text(encoding="utf-8"))


def _golden_materials():
    text = (FIXTURES / "materials" / "note.md").read_text(encoding="utf-8")
    return [Material(name="note.md", kind="md", text=text,
                     tokens=(len(text) + 2) // 3)]


def test_system_prompt_snapshot():
    """Снимок; при осознанном изменении промта — обновить golden и сказать в отчёте."""
    addendum = "Критерии оценки: опыт, системность, коммуникация."
    system = system_prompt(profile="Аналитик, веду интервью.",
                           brief=_golden_brief(), addendum=addendum,
                           materials=_golden_materials())
    assert system == GOLDEN.read_text(encoding="utf-8")


def test_system_prompt_stable_prefix_before_materials():
    addendum = "Критерии оценки: опыт, системность."
    a = system_prompt(profile="p", brief=_golden_brief(), addendum=addendum,
                      materials=_golden_materials())
    b = system_prompt(profile="p", brief=_golden_brief(), addendum=addendum, materials=[])
    # Префикс до материалов (роль → профиль → бриф → дополнение) не зависит от материалов;
    # при пустых материалах за префиксом сразу схема.
    assert a.split("=== МАТЕРИАЛЫ ===")[0] == b.split("=== СХЕМА ОТВЕТА ===")[0]
    assert "=== МАТЕРИАЛЫ ===" not in b


def test_system_prompt_empty_profile_section_skipped():
    system = system_prompt(profile="  ", brief=_golden_brief(), addendum="", materials=[])
    assert "ПРОФИЛЬ" not in system
    assert system.startswith(prompt.ROLE)


def test_turn_message_labels_silence_agenda_notes():
    lines = [{"ch": "them", "label": "Иван", "t0": 1, "t1": 2, "text": "Вопрос?"},
             {"ch": "me", "label": "Я", "t0": 3, "t1": 4, "text": "Ответ"}]
    msg = turn_message(elapsed_sec=120, expected_min=60, lines=lines,
                       agenda_manual=[{"item": "Кейс-задача", "status": "done"}],
                       notes="проверить метрики")
    assert msg.startswith("Прошло 2 из 60 мин.")
    assert "Иван: Вопрос?" in msg and "Я: Ответ" in msg
    assert "Повестка вручную:\n- Кейс-задача → закрыт" in msg
    assert "Заметки:\nпроверить метрики" in msg
    assert msg.endswith("Дай подсказки для «Я» по правилам и схеме.")

    silence = turn_message(elapsed_sec=0, expected_min=30, lines=[], agenda_manual=[], notes="")
    assert "(тишина)" in silence
    assert "Повестка вручную" not in silence and "Заметки" not in silence


def test_finish_message_mentions_criteria_only_when_has_criteria():
    base = dict(elapsed_sec=3540, expected_min=60, lines=[], notes="")
    without = finish_message(has_criteria=False, **base)
    with_ = finish_message(has_criteria=True, **base)
    assert "критери" not in without
    assert "assessment" in with_
    assert without.startswith("Звонок окончен: прошло 59 из 60 мин.")


def test_detail_and_warm_messages():
    assert detail_message({"type": "ask", "text": "Спроси про кейс"}).startswith(
        "Раскрой карточку «Спроси про кейс»")
    assert "JSON" in detail_message({"type": "ask", "text": "x"})
    assert warm_message() == "Готов."
    assert context_tokens("абв") == 1
