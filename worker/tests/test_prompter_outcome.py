"""Тесты P1: рендер итогов в markdown (§4.1, форма [предложено])."""

from mlaud_worker.prompter.outcome import render_markdown

OUTCOME = {
    "goal_result": "partial",
    "reason": "кейс-задачу не успели",
    "summary": "кандидат сильный",
    "decisions": ["дойти до кейса во второй встрече"],
    "next_steps": ["отправить тестовое"],
    "open_questions": [],
    "assessment": [{"criterion": "системность", "verdict": "да",
                    "evidence": "разложил задачу по шагам"}],
}


def test_render_markdown_sections_and_empty_lists():
    md = render_markdown(OUTCOME, title="Интервью — Иван", call_id="2026-09-04_15-30-05",
                         started_at="2026-09-04T15:30:05+03:00",
                         notes=["спросить про зарплатные ожидания"])
    lines = md.splitlines()
    assert lines[0] == "# Итоги: Интервью — Иван"
    assert "результат по цели: частично" in lines[1]
    assert "2026-09-04_15-30-05" in lines[1]
    assert "## Кратко" in lines and "кандидат сильный" in lines
    assert "- дойти до кейса во второй встрече" in lines
    assert "## Открытые вопросы" in lines
    assert "—" in lines                      # пустой список
    assert "| критерий | вердикт | основание |" in lines
    assert "| системность | да | разложил задачу по шагам |" in lines
    assert "## Заметки" in lines and "спросить про зарплатные ожидания" in lines


def test_render_markdown_without_assessment_and_notes():
    md = render_markdown({**OUTCOME, "assessment": []}, title="X", call_id="c",
                         started_at="s", notes=[])
    assert "Оценка по критериям" not in md
    assert "Заметки" not in md
    assert md.endswith("\n")


def test_render_markdown_goal_labels():
    for goal, label in (("achieved", "достигнута"), ("not", "нет")):
        md = render_markdown({**OUTCOME, "goal_result": goal}, title="X", call_id="c",
                             started_at="s", notes=[])
        assert f"результат по цели: {label}" in md
