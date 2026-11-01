"""Тесты P1: материалы — извлечение каждого типа, скан, бюджет, отчёт."""

import json
from pathlib import Path

import pytest

from mlaud_worker.prompter.materials import UNSUPPORTED, estimate_tokens, extract, load_materials, report

FIXTURES = Path(__file__).parent / "fixtures" / "materials"


def test_estimate_tokens():
    assert estimate_tokens("абв") == 1          # (3 + 2) // 3
    assert estimate_tokens("") == 0
    assert estimate_tokens("a" * 4) == 2


def test_extract_each_type_matches_tokens_json():
    pytest.importorskip("pypdf", reason="нет сети для установки pypdf (§0.1)")
    tokens = json.loads((FIXTURES / "tokens.json").read_text(encoding="utf-8"))
    for name, want in tokens.items():
        material = extract(FIXTURES / name)
        assert material.warning is None, (name, material.warning)
        assert material.kind == name.rsplit(".", 1)[1]
        assert material.tokens == want, name


def test_srt_strips_timecodes():
    material = extract(FIXTURES / "sub.srt")
    assert "-->" not in material.text
    assert "1" != material.text.splitlines()[0][:1] or material.text.startswith("Добрый")
    assert material.text.splitlines() == ["Добрый день", "Расскажите про кейс"]


def test_scan_pdf_rejected_with_warning():
    pytest.importorskip("pypdf")
    material = extract(FIXTURES / "scan.pdf")
    assert material.warning == "нет текстового слоя, пропущен"
    assert material.text == ""


def test_unsupported_extension_warning(tmp_path):
    path = tmp_path / "data.bin"
    path.write_bytes(b"\x00\x01")
    material = extract(path)
    assert material.warning == UNSUPPORTED
    assert material.text == ""


def test_load_materials_budget_marks_largest_over(tmp_path):
    small = tmp_path / "a.md"
    small.write_text("коротко", encoding="utf-8")            # 1 токен
    big = tmp_path / "big.md"
    big.write_text("длинный " * 30, encoding="utf-8")
    (tmp_path / "skip.bin").write_bytes(b"\x00")
    included, over = load_materials(tmp_path, budget=100)
    assert [m.name for m in included] == ["a.md", "big.md"]  # по возрастанию tokens
    assert over == []
    included, over = load_materials(tmp_path, budget=5)
    assert [m.name for m in included] == ["a.md"]
    assert over == ["big.md"]                                # самый большой — в over
    # предупреж­дённый (bin) не попадает никуда
    assert "skip.bin" not in over


def test_report_shape(tmp_path):
    (tmp_path / "a.md").write_text("текст", encoding="utf-8")
    (tmp_path / "big.md").write_text("длинный " * 40, encoding="utf-8")
    (tmp_path / "scan.bin").write_bytes(b"\x00")
    data = report(tmp_path, budget=5)
    assert set(data) == {"materials", "total", "budget", "over"}
    assert data["budget"] == 5
    assert data["over"] == ["big.md"]
    assert data["total"] == sum(m["tokens"] for m in data["materials"]
                                if m["name"] == "a.md")
    kinds = {m["name"]: m for m in data["materials"]}
    assert kinds["scan.bin"]["warning"] == UNSUPPORTED
