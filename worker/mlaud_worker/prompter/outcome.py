"""Рендер итогов звонка в outcome.md (stage4-brief §4.1, форма [предложено])."""

GOAL_LABELS = {"achieved": "достигнута", "partial": "частично", "not": "нет"}


def _bullets(rows: list) -> str:
    if not rows:
        return "—"
    return "\n".join(f"- {row}" for row in rows)


def render_markdown(outcome: dict, *, title: str, call_id: str, started_at: str, notes: list) -> str:
    goal = GOAL_LABELS.get(outcome.get("goal_result"), "?")
    lines = [
        f"# Итоги: {title}",
        f"Звонок {call_id} · {started_at} · результат по цели: {goal}",
        "",
        outcome.get("reason", ""),
        "",
        "## Кратко",
        outcome.get("summary", ""),
        "",
        "## Решения",
        _bullets(outcome.get("decisions", [])),
        "",
        "## Следующие шаги",
        _bullets(outcome.get("next_steps", [])),
        "",
        "## Открытые вопросы",
        _bullets(outcome.get("open_questions", [])),
    ]
    assessment = outcome.get("assessment") or []
    if assessment:
        lines += [
            "",
            "## Оценка по критериям",
            "| критерий | вердикт | основание |",
            "| --- | --- | --- |",
        ]
        for row in assessment:
            lines.append(f"| {row.get('criterion', '')} | {row.get('verdict', '')} | {row.get('evidence', '')} |")
    if notes:
        lines += ["", "## Заметки", *notes]
    return "\n".join(lines).rstrip("\n") + "\n"
