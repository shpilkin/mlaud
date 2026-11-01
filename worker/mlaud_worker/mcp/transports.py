"""Транспорты MCP: Streamable HTTP (для приложения) и stdio (для отладки и CLI-агентов).

HTTP — подмножество Streamable HTTP (MCP, basic/transports): POST /mcp с одним
JSON-RPC сообщением, ответ — application/json; потока SSE и сессий нет, их спецификация
разрешает не поддерживать. Только 127.0.0.1, только с токеном.
"""

import hmac
import io
import json
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from .protocol import Server, _error, log

MAX_BODY = 160 * 1024 * 1024  # base64 файла до 100 МБ + запас
_LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1", "[::1]"}


def _origin_allowed(origin: str | None) -> bool:
    """Защита от DNS rebinding: Origin браузера должен быть локальным, если он есть."""
    if not origin:
        return True
    host = urlsplit(origin).hostname
    return host in _LOCAL_HOSTS


def make_http_server(server: Server, token: str, host: str = "127.0.0.1",
                     port: int = 8767, path: str = "/mcp") -> ThreadingHTTPServer:
    expected = f"Bearer {token}".encode()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "mlaud-mcp"

        def log_message(self, fmt, *args):  # без журнала каждого запроса в stderr
            pass

        def _send(self, code: int, body: dict | None = None, extra: dict | None = None):
            data = json.dumps(body, ensure_ascii=False).encode() if body is not None else b""
            self.send_response(code)
            if body is not None:
                self.send_header("Content-Type", "application/json; charset=utf-8")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _guard(self) -> bool:
            if urlsplit(self.path).path != path:
                self._send(404, {"error": "not found"})
                return False
            if not _origin_allowed(self.headers.get("Origin")):
                self._send(403, {"error": "origin not allowed"})
                return False
            got = (self.headers.get("Authorization") or "").encode()
            if not hmac.compare_digest(got, expected):
                self._send(401, {"error": "unauthorized"},
                           {"WWW-Authenticate": 'Bearer realm="mlaud"'})
                return False
            return True

        def do_POST(self):
            if not self._guard():
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if length < 0 or length > MAX_BODY:
                self._send(413, _error(None, -32600, "body too large"))
                return
            try:
                msg = json.loads(self.rfile.read(length) or b"null")
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send(400, _error(None, -32700, "parse error"))
                return
            reply = server.respond(msg)
            if reply is None:
                self._send(202)
            else:
                self._send(200, reply)

        def do_GET(self):
            # Поток уведомлений сервера не поддерживается — спецификация велит 405.
            if self._guard():
                self._send(405, None, {"Allow": "POST"})

        def do_DELETE(self):
            if self._guard():
                self._send(405, None, {"Allow": "POST"})

    httpd = ThreadingHTTPServer((host, port), Handler)
    httpd.daemon_threads = True
    return httpd


def serve_http(server: Server, token: str, port: int, events, stdin) -> int:
    """Слушать до EOF на stdin: приложение держит трубу, EOF = родителя нет, порт свободен."""
    try:
        httpd = make_http_server(server, token, port=port)
    except OSError as e:
        _event(events, {"t": "error", "message": f"порт {port} занят или недоступен: {e}"})
        return 2
    threading.Thread(target=httpd.serve_forever, name="mlaud-mcp-http", daemon=True).start()
    _event(events, {"t": "ready", "port": httpd.server_address[1]})
    log(f"слушаю http://127.0.0.1:{httpd.server_address[1]}/mcp")
    for line in stdin:
        try:
            if json.loads(line).get("t") == "quit":
                break
        except (json.JSONDecodeError, AttributeError):
            continue
    httpd.shutdown()
    httpd.server_close()
    return 0


def _event(out, msg: dict) -> None:
    out.write(json.dumps(msg, ensure_ascii=False) + "\n")
    out.flush()


class StdioLoop:
    """stdio: чтение в главном потоке, вызовы инструментов — в одном рабочем потоке,
    чтобы ping и cancel не ждали конца длинной записи."""

    def __init__(self, server: Server, out):
        self.server = server
        self.out = out
        self._write_lock = threading.Lock()
        self._pool = ThreadPoolExecutor(max_workers=1)
        self._cancelled: set = set()

    def send(self, msg: dict) -> None:
        line = json.dumps(msg, ensure_ascii=False)
        with self._write_lock:
            self.out.write(line + "\n")
            self.out.flush()

    def handle_line(self, line: str) -> None:
        line = line.strip()
        if not line:
            return
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            self.send(_error(None, -32700, "parse error"))
            return
        if isinstance(msg, dict) and msg.get("method") == "notifications/cancelled":
            self._cancelled.add((msg.get("params") or {}).get("requestId"))
            return
        if isinstance(msg, dict) and msg.get("method") == "tools/call" and "id" in msg:
            self._pool.submit(self._call, msg)
            return
        reply = self.server.respond(msg)
        if reply is not None:
            self.send(reply)

    def _call(self, msg: dict) -> None:
        reply = self.server.respond(msg)
        if msg["id"] in self._cancelled:
            self._cancelled.discard(msg["id"])
            return
        if reply is not None:
            self.send(reply)

    def run(self, stdin) -> None:
        for line in stdin:
            self.handle_line(line)
        self.close()

    def close(self) -> None:
        self._pool.shutdown(wait=True)


def utf8_stdin():
    return io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace")
