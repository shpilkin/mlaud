"""brief.md: разбор и каноническая запись (stage4-brief §3.1). Канонические байты совпадают
с Swift BriefParser.encode — обе стороны проверяются одними фикстурами."""

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

SECTION_NAMES = ("Задача встречи", "Собеседник", "Скрипт / методология", "Учитывать / избегать")
ADDENDUM_SECTION = "Дополнение к промту"
_KNOWN_SECTIONS = set(SECTION_NAMES) | {ADDENDUM_SECTION}
_SCALAR_KEYS = {"title", "template", "mode", "expected_min", "counterpart", "goal", "prompter", "model"}
_PLAN_RE = re.compile(r"\((\d+)\)$")


@dataclass
class AgendaEntry:
    text: str
    plan_min: Optional[int] = None


@dataclass
class Brief:
    title: str = ""
    template: str = "custom"
    mode: str = "vks"
    expected_min: int = 60
    counterpart: str = ""
    goal: str = ""
    agenda: list = field(default_factory=list)          # [AgendaEntry]
    prompter: bool = False
    model: str = "default"
    sections: dict = field(default_factory=dict)        # известные разделы, ключ — заголовок без «## »
    extra: list = field(default_factory=list)           # [(key, value)] в порядке исходника
    extra_sections: list = field(default_factory=list)  # [(title, text)] в порядке исходника


class BriefError(ValueError):
    pass


def _cut_comment(value: str) -> str:
    hash_pos = value.find(" #")
    if hash_pos >= 0:
        value = value[:hash_pos]
    return value.strip()


def parse_brief(text: str) -> Brief:
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines or lines[0].strip() != "---":
        raise BriefError("нет фронт-маттера")
    brief = Brief()
    extras = []
    end = None
    for idx in range(1, len(lines)):
        raw = lines[idx]
        line = raw.strip()
        if line == "---":
            end = idx
            break
        if not line:
            continue
        if line == "agenda:":
            continue
        if line.startswith("- ") and raw[:1] in (" ", "\t"):
            item = line[2:].strip()
            plan = None
            match = _PLAN_RE.search(item)
            if match and int(match.group(1)) > 0:
                inner = item[: match.start()]
                item = inner.strip()
                plan = int(match.group(1))
            brief.agenda.append(AgendaEntry(text=item, plan_min=plan))
            continue
        if ":" in line:
            key, _, value = line.partition(":")
            value = _cut_comment(value)
            if key in _SCALAR_KEYS:
                if key == "title":
                    brief.title = value
                elif key == "template":
                    brief.template = value or "custom"
                elif key == "mode":
                    if value not in ("vks", "offline"):
                        raise BriefError(f"mode должен быть vks|offline, получено {value!r} (строка {idx + 1})")
                    brief.mode = value
                elif key == "expected_min":
                    try:
                        brief.expected_min = int(value)
                    except ValueError:
                        raise BriefError(f"expected_min не число: {value!r} (строка {idx + 1})")
                    if brief.expected_min <= 0:
                        raise BriefError(f"expected_min должен быть > 0 (строка {idx + 1})")
                elif key == "counterpart":
                    brief.counterpart = value
                elif key == "goal":
                    brief.goal = value
                elif key == "prompter":
                    if value not in ("on", "off"):
                        raise BriefError(f"prompter должен быть on|off, получено {value!r} (строка {idx + 1})")
                    brief.prompter = value == "on"
                elif key == "model":
                    brief.model = value or "default"
            else:
                extras.append((key, value))
    if end is None:
        raise BriefError("фронт-маттер не закрыт")
    brief.extra = extras

    current_title = None
    current_lines: list = []
    sections: dict = {}
    extra_sections: list = []

    def flush():
        if current_title is None:
            return
        body = "\n".join(current_lines).strip()
        if current_title in _KNOWN_SECTIONS:
            sections[current_title] = body
        else:
            extra_sections.append((current_title, body))

    started = False
    for raw in lines[end + 1:]:
        if not started:
            if raw.strip():
                started = True
            else:
                continue
        if raw.startswith("## "):
            flush()
            current_lines = []
            current_title = raw[3:].strip()
        elif current_title is not None:
            current_lines.append(raw)
    flush()
    brief.sections = sections
    brief.extra_sections = extra_sections
    return brief


def render(brief: Brief) -> str:
    """Каноническая форма §3.1 — байт в байт как BriefParser.encode в Swift."""

    def scalar(key: str, value: str) -> str:
        return f"{key}:\n" if not value else f"{key}: {value}\n"

    out = "---\n"
    out += scalar("title", brief.title)
    out += scalar("template", brief.template)
    out += scalar("mode", brief.mode)
    out += scalar("expected_min", str(brief.expected_min))
    out += scalar("counterpart", brief.counterpart)
    out += scalar("goal", brief.goal)
    out += "agenda:\n"
    for entry in brief.agenda:
        plan = f" ({entry.plan_min})" if entry.plan_min is not None else ""
        out += f"  - {entry.text}{plan}\n"
    out += scalar("prompter", "on" if brief.prompter else "off")
    out += scalar("model", brief.model)
    for key, value in brief.extra:
        out += scalar(key, value)
    out += "---\n"
    parts = []
    for name in list(SECTION_NAMES) + [ADDENDUM_SECTION]:
        if name in brief.sections:
            text = brief.sections[name]
            parts.append(f"## {name}\n{text}" if text else f"## {name}")
    for title, text in brief.extra_sections:
        parts.append(f"## {title}\n{text}" if text else f"## {title}")
    if not parts:
        return out
    return out + "\n" + "\n\n".join(parts) + "\n"


def load_brief(brief_dir: Path) -> Brief:
    return parse_brief((brief_dir / "brief.md").read_text(encoding="utf-8"))


def them_label(counterpart: str) -> str:
    """До первой запятой; пусто → «Собеседник» (= ChannelsSidecar.themLabel)."""
    head = counterpart.split(",", 1)[0].strip()
    return head or "Собеседник"


def template_addendum(templates_dir: Path, slug: str) -> str:
    """Только раздел «Дополнение к промту» шаблона; нет файла/раздела → пусто."""
    path = templates_dir / f"{slug}.md"
    if not path.exists():
        return ""
    try:
        brief = parse_brief(path.read_text(encoding="utf-8"))
    except BriefError:
        return ""
    return brief.sections.get(ADDENDUM_SECTION, "").strip()
