"""python -m mlaud_worker.mcp [--http]

--http — режим приложения: Streamable HTTP на 127.0.0.1:$MLAUD_MCP_PORT с токеном
$MLAUD_MCP_TOKEN; события запуска — JSON-строки в stdout, EOF на stdin = выход.
Без флага — stdio MCP для отладки и CLI-агентов.
"""

import os
import sys

from .protocol import Server, log
from .tools import TOOLS, Engine
from .transports import StdioLoop, serve_http, utf8_stdin

DEFAULT_PORT = 8767
DEFAULT_IDLE_SEC = 600.0


def _protocol_stdout():
    """Отдельный дескриптор под протокол; fd 1 уводится в stderr, чтобы печать библиотек
    (в том числе из C) не портила поток JSON."""
    proto = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    sys.stdout.flush()
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return proto


def _reexec(out, argv) -> None:
    """Тот же процесс заново: PID и трубы к приложению остаются, память torch уходит."""
    log("перезапуск процесса, чтобы вернуть память диаризации")
    out.flush()
    os.dup2(out.fileno(), 1)
    os.execv(sys.executable, [sys.executable, "-m", "mlaud_worker.mcp", *argv])


def main(argv=None) -> int:
    from ..__main__ import _float_env, build_config, load_dotenv

    argv = sys.argv[1:] if argv is None else argv
    sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace")
    out = _protocol_stdout()
    load_dotenv()
    engine = Engine(build_config())
    idle = _float_env("MLAUD_MCP_IDLE_SEC", DEFAULT_IDLE_SEC)
    server = Server(engine, TOOLS)
    if "--http" in argv:
        engine.start_reaper(idle, on_recycle=lambda: _reexec(out, argv))
        token = os.environ.get("MLAUD_MCP_TOKEN", "")
        if len(token) < 32:
            out.write('{"t":"error","message":"MLAUD_MCP_TOKEN не задан или короче 32 символов"}\n')
            out.flush()
            return 2
        try:
            port = int(os.environ.get("MLAUD_MCP_PORT") or DEFAULT_PORT)
        except ValueError:
            port = DEFAULT_PORT
        return serve_http(server, token, port, out, utf8_stdin())
    engine.start_reaper(idle)
    log(f"stdio, pid {os.getpid()}")
    StdioLoop(server, out).run(utf8_stdin())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
