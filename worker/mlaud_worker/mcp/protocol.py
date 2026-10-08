"""Ядро MCP без транспорта: JSON-RPC 2.0, initialize/ping/tools/list/tools/call.

Инструмент — функция `(engine, args) -> str`. Ошибку ввода она сообщает через ToolError:
агент получает её текстом с `isError`, а не сбоем протокола (MCP, server/tools).
"""

import sys
from dataclasses import dataclass, field
from typing import Callable

SERVER_NAME = "mlaud"
SERVER_VERSION = "1.1.0"
PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
INSTRUCTIONS = (
    "MLaud — локальное распознавание речи и архив транскриптов на этом Mac. "
    "transcribe ничего не сохраняет и в Niti не отправляет."
)


class ToolError(Exception):
    """Ошибка, которую агент должен увидеть текстом (isError)."""


class RpcError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


@dataclass
class Tool:
    name: str
    title: str
    description: str
    handler: Callable[[object, dict], str]
    properties: dict = field(default_factory=dict)
    required: list = field(default_factory=list)
    read_only: bool = True

    def describe(self) -> dict:
        schema = {"type": "object", "properties": self.properties}
        if self.required:
            schema["required"] = self.required
        return {"name": self.name, "title": self.title, "description": self.description,
                "inputSchema": schema,
                "annotations": {"readOnlyHint": self.read_only, "openWorldHint": False}}


def log(msg: str) -> None:
    print(f"[mlaud-mcp] {msg}", file=sys.stderr, flush=True)


class Server:
    """Отвечает на одно сообщение. Потокобезопасен, если потокобезопасны инструменты."""

    def __init__(self, engine, tools: list[Tool]):
        self.engine = engine
        self.tools = {t.name: t for t in tools}

    def respond(self, msg) -> dict | None:
        """Ответ на сообщение клиента; None — для уведомлений и ответов клиента."""
        if not isinstance(msg, dict):
            return _error(None, -32600, "invalid request")
        method, rid = msg.get("method"), msg.get("id")
        params = msg.get("params") or {}
        if method is None or rid is None:
            return None
        if not isinstance(params, dict):
            return _error(rid, -32602, "params must be an object")
        try:
            return {"jsonrpc": "2.0", "id": rid, "result": self._dispatch(method, params)}
        except RpcError as e:
            return _error(rid, e.code, str(e))

    def _dispatch(self, method: str, params: dict) -> dict:
        if method == "initialize":
            asked = params.get("protocolVersion")
            return {
                "protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "instructions": INSTRUCTIONS,
            }
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": [t.describe() for t in self.tools.values()]}
        if method == "tools/call":
            return self._call(params)
        raise RpcError(-32601, f"method not found: {method}")

    def _call(self, params: dict) -> dict:
        tool = self.tools.get(params.get("name"))
        if tool is None:
            raise RpcError(-32602, f"unknown tool: {params.get('name')}")
        args = params.get("arguments") or {}
        if not isinstance(args, dict):
            raise RpcError(-32602, "arguments must be an object")
        try:
            text, is_error = tool.handler(self.engine, args), False
        except ToolError as e:
            text, is_error = str(e), True
        except Exception as e:  # noqa: BLE001 — сбой модели не должен ронять сервер
            log(f"{tool.name} failed: {e!r}")
            text, is_error = f"ошибка: {e}", True
        return {"content": [{"type": "text", "text": text}], "isError": is_error}


def _error(rid, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}
