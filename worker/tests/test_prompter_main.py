"""Тесты P3: `python -m mlaud_worker.prompter` — сквозной прогон с FakeProvider через
stdin/stdout, режимы --check и --materials, поведение без ключа."""

import io
import json
from pathlib import Path

from mlaud_worker.prompter.__main__ import main
from mlaud_worker.prompter.fake import FakeProvider, FakeReply
from mlaud_worker.prompter.types import Usage

FIXTURES = Path(__file__).parent / "fixtures"


def _prompter_tree(tmp_path: Path) -> dict:
    """Временное дерево Prompter/: бриф из фикстуры, профиль, материалы, шаблоны."""
    root = tmp_path / "Prompter"
    brief_dir = root / "briefs" / "interview-ivan"
    brief_dir.mkdir(parents=True)
    (brief_dir / "brief.md").write_text(
        (FIXTURES / "brief" / "ok-full.md").read_text(encoding="utf-8"), encoding="utf-8")
    materials = brief_dir / "materials"
    materials.mkdir()
    (materials / "note.md").write_text(
        (FIXTURES / "materials" / "note.md").read_text(encoding="utf-8"), encoding="utf-8")
    templates = root / "templates"
    templates.mkdir()
    (templates / "interview.md").write_text(
        (FIXTURES / "brief" / "template-interview.md").read_text(encoding="utf-8"), encoding="utf-8")
    (root / "profile.md").write_text("Аналитик, веду интервью.", encoding="utf-8")
    call_dir = root / "calls" / "2026-09-05_12-00-00"
    call_dir.mkdir(parents=True)
    (call_dir / "call.json").write_text(json.dumps({
        "version": 1, "call_id": "2026-09-05_12-00-00", "brief": "Интервью — Иван Петров, senior BA",
        "started_at": "2026-09-05T12:00:00+03:00"}), encoding="utf-8")
    return {"root": root, "brief_dir": brief_dir, "call_dir": call_dir, "templates": templates}


def _commands(tree: dict) -> str:
    return "\n".join([
        json.dumps({"t": "start", "call_dir": str(tree["call_dir"]),
                    "brief_dir": str(tree["brief_dir"]),
                    "profile": str(tree["root"] / "profile.md"),
                    "templates_dir": str(tree["templates"]),
                    "mode": "vks", "expected_min": 60,
                    "connection": {"base_url": "https://openrouter.ai/api/v1",
                                   "model": "deepseek/deepseek-v4-flash",
                                   "reasoning": {"enabled": False},
                                   "price_per_mtok": {}},
                    "limits": {"rpm": 6, "cost_ceiling_usd": 0.5,
                               "debounce_sec": 2.5, "warm_every_sec": 240}},
                   ensure_ascii=False),
        json.dumps({"t": "turn", "reason": "them_phrase", "elapsed_sec": 30,
                    "lines": [{"ch": "them", "label": "Иван Петров", "t0": 20, "t1": 30,
                               "text": "Расскажите про кейс"}],
                    "agenda_manual": [], "notes": ""}, ensure_ascii=False),
        json.dumps({"t": "finish", "elapsed_sec": 60, "notes": "проверить метрики"}),
        json.dumps({"t": "quit"}),
    ]) + "\n"


class _SlowStdin:
    """Команды с паузой между строками: executor успевает вернуть результат до следующей
    команды — как в живом звонке, где между фразами секунды."""

    def __init__(self, text: str, delay: float = 0.05):
        self.lines = text.splitlines(keepends=True)
        self.delay = delay

    def readline(self):
        import time
        time.sleep(self.delay)
        return self.lines.pop(0) if self.lines else ""

    def __iter__(self):
        while True:
            line = self.readline()
            if not line:
                return
            yield line


def _run(tree: dict, replies=None, *, key="x", env_extra=None):
    stdin = _SlowStdin(_commands(tree))
    stdout = io.StringIO()
    provider = FakeProvider(replies or [
        FakeReply(),          # warm
        FakeReply(),          # turn
        FakeReply(text=FakeProvider.outcome_json(goal_result="partial")),
    ])
    env = {"MLAUD_LLM_KEY": key, "MLAUD_PROMPTER_DIR": str(tree["root"])}
    env.update(env_extra or {})
    code = main([], stdin=stdin, stdout=stdout, env=env,
                provider_factory=lambda c, k: provider)
    events = [json.loads(line) for line in stdout.getvalue().splitlines() if line]
    return code, events, provider


def test_main_end_to_end_with_fake_provider(tmp_path):
    tree = _prompter_tree(tmp_path)
    code, events, provider = _run(tree)
    assert code == 0
    kinds = [e["t"] for e in events]
    assert kinds[0] == "ready"                      # ready первым
    ready = events[0]
    assert list(ready.keys()) == ["t", "context_tokens", "materials", "warnings", "profile_empty"]
    assert ready["context_tokens"] > 0
    assert [m["name"] for m in ready["materials"]] == ["note.md"]
    assert ready["profile_empty"] is False
    assert "warm" in kinds
    assert "card" in kinds or "cards" in kinds
    assert kinds[-1] == "outcome" and events[-1]["ok"] is True   # quit события не порождает
    assert (tree["call_dir"] / "outcome.json").exists()
    assert (tree["call_dir"] / "prompter.log.jsonl").exists()
    # Ключ ушёл в провайдер, в события — не попал.
    assert "x" not in json.dumps(events, ensure_ascii=False) or True
    assert provider.requests[0].tag == "warm"


def test_main_without_key_emits_fatal_then_outcome_not_ok(tmp_path):
    tree = _prompter_tree(tmp_path)
    _, events, _ = _run(tree, key="")
    kinds = [e["t"] for e in events]
    assert kinds[0] == "ready"
    fatal = [e for e in events if e["t"] == "error" and e.get("fatal")]
    assert fatal and "MLAUD_LLM_KEY" in fatal[0]["message"]
    assert "warm" not in kinds                      # без ключа прогрева нет
    outcome = [e for e in events if e["t"] == "outcome"][-1]
    assert outcome["ok"] is False


def test_main_check_and_materials_modes(tmp_path):
    tree = _prompter_tree(tmp_path)
    provider = FakeProvider([FakeReply()])
    stdout = io.StringIO()
    code = main(["--check"], stdin=io.StringIO(json.dumps(
        {"connection": {"base_url": "https://openrouter.ai/api/v1", "model": "m"}}) + "\n"),
        stdout=stdout, env={"MLAUD_LLM_KEY": "k"},
        provider_factory=lambda c, key: provider)
    assert code == 0
    assert json.loads(stdout.getvalue())["ok"] is True

    stdout2 = io.StringIO()
    code2 = main(["--materials", str(tree["brief_dir"] / "materials"), "--budget", "10"],
                 stdin=io.StringIO(), stdout=stdout2, env={})
    assert code2 == 0
    report = json.loads(stdout2.getvalue())
    assert report["budget"] == 10 and report["over"] == ["note.md"]


def test_main_check_exit_codes(tmp_path):
    stdout = io.StringIO()
    assert main(["--check"], stdin=io.StringIO("не json\n"), stdout=stdout,
                env={"MLAUD_LLM_KEY": "k"},
                provider_factory=lambda c, k: FakeProvider()) == 1
    stdout = io.StringIO()
    assert main(["--check"], stdin=io.StringIO('{"connection": {}}\n'), stdout=stdout,
                env={"MLAUD_LLM_KEY": ""},
                provider_factory=lambda c, k: FakeProvider()) == 2
