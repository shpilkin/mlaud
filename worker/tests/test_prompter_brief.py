"""Тесты P1: brief.md — разбор, каноническая запись, ошибки, шаблонное дополнение."""

import json
from pathlib import Path

import pytest

from mlaud_worker.prompter.brief import (BriefError, parse_brief, render,
                                         template_addendum, them_label)

FIXTURES = Path(__file__).parent / "fixtures" / "brief"


def test_parse_brief_full_matches_fixture_json():
    brief = parse_brief((FIXTURES / "ok-full.md").read_text(encoding="utf-8"))
    expected = json.loads((FIXTURES / "ok-full.json").read_text(encoding="utf-8"))
    assert brief.title == expected["title"]
    assert brief.template == expected["template"]
    assert brief.mode == expected["mode"]               # комментарий срезан
    assert brief.expected_min == expected["expected_min"]
    assert brief.counterpart == expected["counterpart"]
    assert brief.goal == expected["goal"]
    assert brief.prompter is expected["prompter"]
    assert brief.model == expected["model"]
    assert [{"text": e.text, "plan_min": e.plan_min} for e in brief.agenda] == expected["agenda"]
    assert brief.sections == expected["sections"]
    assert brief.extra == [] and brief.extra_sections == []

    minimal = parse_brief((FIXTURES / "ok-minimal.md").read_text(encoding="utf-8"))
    assert minimal.prompter is False
    assert minimal.template == "custom" and minimal.expected_min == 60
    assert minimal.agenda == []


def test_render_roundtrip_is_canonical():
    for name in ("ok-full", "ok-minimal"):
        text = (FIXTURES / f"{name}.md").read_text(encoding="utf-8")
        canonical = (FIXTURES / f"{name}.canonical.md").read_text(encoding="utf-8")
        once = render(parse_brief(text))
        assert once == canonical, name
        assert render(parse_brief(once)) == canonical, name
        assert render(parse_brief(render(parse_brief(once)))) == canonical, name


def test_parse_errors():
    with pytest.raises(BriefError):
        parse_brief((FIXTURES / "bad-mode.md").read_text(encoding="utf-8"))
    with pytest.raises(BriefError):
        parse_brief((FIXTURES / "bad-no-frontmatter.md").read_text(encoding="utf-8"))
    with pytest.raises(BriefError):
        parse_brief("---\ntitle: X\nmode: vks\nexpected_min: abc\n---\n")
    with pytest.raises(BriefError):
        parse_brief("---\ntitle: X\nmode: vks\nprompter: maybe\n---\n")


def test_unknown_keys_and_sections_survive():
    source = ("---\ntitle: T\ntrello: board-42\nmode: vks\n---\n"
              "## Собеседник\nКто это.\n\n## Свой раздел\nСвой текст.\n")
    brief = parse_brief(source)
    assert brief.extra == [("trello", "board-42")]
    assert brief.extra_sections == [("Свой раздел", "Свой текст.")]
    again = parse_brief(render(brief))
    assert again.extra == [("trello", "board-42")]
    assert again.extra_sections == [("Свой раздел", "Свой текст.")]
    assert again.sections["Собеседник"] == "Кто это."


def test_them_label():
    assert them_label("Иван Петров, кандидат") == "Иван Петров"
    assert them_label("Мария") == "Мария"
    assert them_label("") == "Собеседник"


def test_template_addendum_only_that_section(tmp_path):
    template = (FIXTURES / "template-interview.md").read_text(encoding="utf-8")
    (tmp_path / "interview.md").write_text(template, encoding="utf-8")
    addendum = template_addendum(tmp_path, "interview")
    assert addendum.startswith("Критерии оценки")
    assert "Скрипт" not in addendum
    (tmp_path / "custom.md").write_text("---\ntitle:\nmode: vks\n---\n", encoding="utf-8")
    assert template_addendum(tmp_path, "custom") == ""
    assert template_addendum(tmp_path / "nope", "custom") == ""
