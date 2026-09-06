"""Файлы подсказчика вне архива: папка звонка в `Prompter/calls`, путь итогов, цель брифа
(stage4-brief §3.7). Используется конвейером при обработке записи звонка."""

import json
from pathlib import Path
from typing import Optional

from .prompter.brief import BriefError, parse_brief


def call_dir(cfg, call_id: str) -> Path:
    return cfg.prompter_dir / "calls" / call_id


def outcome_md(cfg, call_id: str) -> Optional[Path]:
    """Существует → путь; итоги опоздали → None (артефакт без outcome_path)."""
    path = call_dir(cfg, call_id) / "outcome.md"
    return path if path.is_file() else None


def goal(cfg, call_id: str) -> Optional[str]:
    """call.json.brief_dir → briefs/<slug>/brief.md → parse_brief().goal; любая ошибка → None."""
    try:
        meta = json.loads((call_dir(cfg, call_id) / "call.json").read_text(encoding="utf-8"))
        slug = meta.get("brief_dir")
        if not slug:
            return None
        brief_path = cfg.prompter_dir / "briefs" / slug / "brief.md"
        return parse_brief(brief_path.read_text(encoding="utf-8")).goal or None
    except (OSError, ValueError, KeyError, BriefError):
        return None


def copy_outcome(src: Path, out_dir: Path, base: str) -> Path:
    """<base>.prompter.md рядом с транскриптом; перезапись при повторной обработке."""
    target = out_dir / f"{base}.prompter.md"
    out_dir.mkdir(parents=True, exist_ok=True)
    target.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
    return target
