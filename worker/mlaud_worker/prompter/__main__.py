"""`python -m mlaud_worker.prompter`: резидентный подсказчик (stage4-brief §2, §4.3) и
одноразовые режимы `--check` / `--materials` (§2.4).

Резидентный цикл [предложено]: поток-читатель stdin кладёт строки в очередь; главный поток
берёт из неё с таймаутом до next_deadline и гоняет Orchestrator строго в одном потоке —
emit не нуждается в локе. HTTP — ThreadPoolExecutor(max_workers=1); дельты стрима и
завершение exchanges возвращаются в ту же очередь. Бюджет материалов — MLAUD_MATERIALS_BUDGET
[предложено]; ключ — только MLAUD_LLM_KEY (FR-12.13)."""

import argparse
import json
import os
import queue
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Optional

from .brief import load_brief, template_addendum
from .materials import Material, load_materials
from .prompt import context_tokens, system_prompt
from .types import Connection, Limits, Provider, ProviderError

MATERIALS_BUDGET_DEFAULT = 120000


def _real_provider(connection: Connection, api_key: str) -> Provider:
    from .providers import OpenAICompatibleProvider

    return OpenAICompatibleProvider(connection, api_key)


def _emit(event: dict, out) -> None:
    out.write(json.dumps(event, ensure_ascii=False) + "\n")
    out.flush()


def _read_profile(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def main(argv: Optional[list] = None, *, stdin=None, stdout=None, env: Optional[dict] = None,
         provider_factory: Callable[[Connection, str], Provider] = _real_provider) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    env = env if env is not None else dict(os.environ)

    parser = argparse.ArgumentParser(prog="mlaud_worker.prompter", allow_abbrev=False)
    parser.add_argument("--check", action="store_true", help="один запрос к шлюзу, max_tokens=1")
    parser.add_argument("--materials", metavar="DIR", help="отчёт по материалам брифа (§2.4)")
    parser.add_argument("--budget", type=int, default=MATERIALS_BUDGET_DEFAULT)
    args = parser.parse_args(argv)

    if args.check:
        return _mode_check(stdin, stdout, env, provider_factory)
    if args.materials:
        from .materials import report
        _emit(report(Path(args.materials), budget=args.budget), stdout)
        return 0
    return _serve(stdin, stdout, env, provider_factory)


def _mode_check(stdin, stdout, env, provider_factory) -> int:
    """stdin — одна строка {"connection": {…}}; stdout — {"ok", "ttft_ms", "model"} | {"ok": false}."""
    try:
        msg = json.loads(stdin.readline())
    except ValueError:
        _emit({"ok": False, "message": "не JSON"}, stdout)
        return 1
    api_key = (env.get("MLAUD_LLM_KEY") or "").strip()
    if not api_key:
        _emit({"ok": False, "message": "нет ключа: MLAUD_LLM_KEY пуст"}, stdout)
        return 2
    try:
        connection = Connection.from_json(msg.get("connection") or {})
    except (KeyError, ValueError) as e:
        _emit({"ok": False, "message": f"подключение: {e}"}, stdout)
        return 1
    provider = provider_factory(connection, api_key)
    try:
        result = provider.check()
        _emit(result, stdout)
        return 0 if result.get("ok") else 1
    finally:
        close = getattr(provider, "close", None)
        if close:
            close()


def _serve(stdin, stdout, env, provider_factory) -> int:
    from .orchestrator import Orchestrator, Request

    lines: "queue.Queue[object]" = queue.Queue()

    def reader():
        try:
            for raw in stdin:
                lines.put(("line", raw))
        finally:
            lines.put(("eof", None))

    threading.Thread(target=reader, daemon=True).start()

    clock = time.perf_counter
    orch: Optional[Orchestrator] = None
    provider = None
    executor = ThreadPoolExecutor(max_workers=1)

    def emit(event: dict) -> None:
        _emit(event, stdout)

    def submit(req: Request) -> None:
        def run():
            try:
                result = provider.complete(req.request,
                                           on_delta=lambda d, r=req: lines.put(("delta", r, d)))
                lines.put(("result", req, result))
            except ProviderError as e:
                lines.put(("error", req, e))
            except Exception as e:  # noqa: BLE001 — неизвестное не должно ронять процесс
                lines.put(("error", req, ProviderError(f"{type(e).__name__}: {e}", retry_in_sec=10)))
        executor.submit(run)

    def handle_start(msg: dict) -> None:
        nonlocal orch, provider
        if orch is not None:
            emit({"t": "error", "message": "start уже был"})
            return
        connection = Connection.from_json(msg.get("connection") or {})
        limits = Limits.from_json(msg.get("limits"))
        call_dir = Path(msg.get("call_dir") or "") if msg.get("call_dir") else None
        budget = int(env.get("MLAUD_MATERIALS_BUDGET") or MATERIALS_BUDGET_DEFAULT)
        try:
            brief_dir = Path(msg.get("brief_dir") or "")
            brief = load_brief(brief_dir)
            profile = _read_profile(msg.get("profile") or "")
            addendum = template_addendum(Path(msg.get("templates_dir") or ""), brief.template)
            materials, _over = load_materials(brief_dir / "materials", budget=budget)
            from .materials import scan
            warned = [m for m in scan(brief_dir / "materials") if m.warning]
            system = system_prompt(profile=profile, brief=brief, addendum=addendum, materials=materials)
        except Exception as e:  # noqa: BLE001 — битый бриф: суфлёр выключен, цикл живёт
            orch = Orchestrator(emit=emit, submit=submit, clock=clock, limits=limits,
                                connection=connection, system_prompt="", expected_min=60, call_dir=call_dir)
            orch.disabled = True
            emit({"t": "error", "message": f"бриф не прочитан: {e}", "fatal": True})
            return
        orch = Orchestrator(emit=emit, submit=submit, clock=clock, limits=limits,
                            connection=connection, system_prompt=system,
                            expected_min=brief.expected_min, call_dir=call_dir,
                            has_criteria="критери" in addendum.lower())
        emit({"t": "ready", "context_tokens": context_tokens(system),
              "materials": [m.report_json() for m in materials],
              "warnings": [f"{m.name}: {m.warning}" for m in warned],
              "profile_empty": not profile.strip()})
        api_key = (env.get("MLAUD_LLM_KEY") or "").strip()
        if not api_key:
            emit({"t": "error", "message": "нет ключа: MLAUD_LLM_KEY пуст", "fatal": True})
        else:
            provider = provider_factory(connection, api_key)
            orch.begin()

    while True:
        timeout = None
        if orch is not None and orch.next_deadline() is not None:
            timeout = max(0.05, orch.next_deadline() - clock())
        try:
            item = lines.get(timeout=timeout)
        except queue.Empty:
            item = None
        if item is not None:
            kind = item[0]
            if kind == "eof":
                break
            if kind == "line":
                raw = item[1].strip()
                if raw:
                    try:
                        msg = json.loads(raw)
                        if not isinstance(msg, dict):
                            raise ValueError("не объект")
                    except ValueError:
                        emit({"t": "error", "message": "не JSON"})
                        msg = None
                    if msg is not None:
                        if msg.get("t") == "quit":
                            break
                        if msg.get("t") == "start":
                            handle_start(msg)
                        elif orch is None:
                            emit({"t": "error", "message": "start ещё не был"})
                        else:
                            try:
                                orch.handle(msg)
                            except Exception as e:  # noqa: BLE001 — плохая команда не роняет процесс
                                emit({"t": "error", "message": f"{type(e).__name__}: {e}"})
            elif kind == "delta" and orch is not None:
                orch.on_delta(item[1], item[2])
            elif kind == "result" and orch is not None:
                orch.on_result(item[1], item[2])
            elif kind == "error" and orch is not None:
                orch.on_error(item[1], item[2])
        if orch is not None:
            deadline = orch.next_deadline()
            if deadline is not None and clock() >= deadline:
                orch.tick()

    executor.shutdown(wait=False)
    if provider is not None:
        close = getattr(provider, "close", None)
        if close:
            close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
