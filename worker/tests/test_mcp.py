"""MCP MLaud: инструменты, протокол, транспорты HTTP и stdio, выгрузка моделей по простою."""

import base64
import io
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from mlaud_worker.audio import AudioDecodeError
from mlaud_worker.config import Config
from mlaud_worker.mcp import protocol
from mlaud_worker.mcp.protocol import Server, ToolError
from mlaud_worker.mcp.tools import (
    TOOLS, Engine, get_transcript, list_transcripts, status, transcribe,
)
from mlaud_worker.mcp.transports import StdioLoop, make_http_server

WORKER_DIR = Path(__file__).resolve().parent.parent
TOKEN = "t" * 40


def make_cfg(tmp_path) -> Config:
    return Config(inbox=tmp_path / "inbox", output=tmp_path / "out",
                  processed=tmp_path / "processed", failed=tmp_path / "failed",
                  service=tmp_path / "service", prompter_dir=tmp_path / "Prompter",
                  router_inbox=tmp_path / "router" / "artifacts_inbox")


class FakeTranscriber:
    def __init__(self, segments=None, error=None):
        self.segments = segments or [
            {"start": 0.0, "end": 2.5, "text": "привет"},
            {"start": 2.5, "end": 5.0, "text": "как дела "},
        ]
        self.error = error
        self.paths = []

    def transcribe(self, path):
        self.paths.append(path)
        assert Path(path).exists()
        if self.error:
            raise self.error
        return list(self.segments)

    def transcribe_words(self, path):
        self.paths.append(path)
        return [{"start": 0.0, "end": 1.0, "text": "привет"},
                {"start": 3.0, "end": 4.0, "text": "пока"}]


class FakeDiarizer:
    def diarize(self, path, num_speakers=None):
        self.num = num_speakers
        return ([{"start": 0.0, "end": 2.0, "speaker": "SPEAKER_00"},
                 {"start": 2.0, "end": 5.0, "speaker": "SPEAKER_01"}], {})


@pytest.fixture
def audio(tmp_path):
    p = tmp_path / "voice.ogg"
    p.write_bytes(b"OggS" + b"\0" * 100)
    return p


def engine(tmp_path, transcriber=None, **kw):
    t = transcriber or FakeTranscriber()
    return Engine(make_cfg(tmp_path), transcriber_factory=lambda: t, **kw)


# --- transcribe ---------------------------------------------------------------------

def test_text_format_joins_segments(tmp_path, audio):
    assert transcribe(engine(tmp_path), {"path": str(audio)}) == "привет как дела"


def test_timestamps_and_srt_formats(tmp_path, audio):
    e = engine(tmp_path)
    assert transcribe(e, {"path": str(audio), "format": "timestamps"}) == (
        "[00:00:00] привет\n[00:00:02] как дела\n")
    srt = transcribe(e, {"path": str(audio), "format": "srt"})
    assert srt.startswith("1\n00:00:00,000 --> 00:00:02,500\nпривет\n")


def test_segments_format_is_json(tmp_path, audio):
    out = json.loads(transcribe(engine(tmp_path), {"path": str(audio), "format": "segments"}))
    assert out == [{"start": 0.0, "end": 2.5, "text": "привет"},
                   {"start": 2.5, "end": 5.0, "text": "как дела"}]


def test_nothing_written_to_archive_or_router(tmp_path, audio):
    """Главное требование: распознавание не трогает архив и не сдаёт артефакт в Niti."""
    transcribe(engine(tmp_path), {"path": str(audio), "format": "timestamps"})
    left = sorted(p.relative_to(tmp_path) for p in tmp_path.rglob("*"))
    assert left == [Path("voice.ogg")]


def test_base64_uses_extension_and_cleans_up(tmp_path):
    t = FakeTranscriber()
    data = base64.b64encode(b"OggS" + b"\1" * 50).decode()
    assert transcribe(engine(tmp_path, t),
                      {"audio_base64": data, "filename": "voice.oga"}) == "привет как дела"
    used = Path(t.paths[0])
    assert used.suffix == ".oga"
    assert not used.exists() and not used.parent.exists()


def test_base64_cleans_up_on_failure(tmp_path):
    t = FakeTranscriber(error=AudioDecodeError("afconvert failed"))
    data = base64.b64encode(b"junk").decode()
    with pytest.raises(ToolError, match="декодировать"):
        transcribe(engine(tmp_path, t), {"audio_base64": data, "filename": "x.webm"})
    assert not Path(t.paths[0]).parent.exists()


@pytest.mark.parametrize("args, msg", [
    ({}, "ровно одно"),
    ({"path": "/a.ogg", "audio_base64": "AAAA"}, "ровно одно"),
    ({"path": "relative.ogg"}, "абсолютный"),
    ({"path": "/nonexistent/voice.ogg"}, "не найден"),
    ({"audio_base64": "не base64!"}, "base64"),
    ({"audio_base64": ""}, "ровно одно"),
    ({"path": "/a.ogg", "format": "html"}, "format"),
    ({"path": "/a.ogg", "num_speakers": 0}, "num_speakers"),
    ({"path": "/a.ogg", "num_speakers": True}, "num_speakers"),
])
def test_bad_arguments(tmp_path, args, msg):
    with pytest.raises(ToolError, match=msg):
        transcribe(engine(tmp_path), args)


def test_empty_file_rejected(tmp_path):
    p = tmp_path / "e.ogg"
    p.write_bytes(b"")
    with pytest.raises(ToolError, match="пустой"):
        transcribe(engine(tmp_path), {"path": str(p)})


def test_silence_reported(tmp_path, audio):
    t = FakeTranscriber(segments=[{"start": 0, "end": 1, "text": "  "}])
    assert transcribe(engine(tmp_path, t), {"path": str(audio)}) == "(речь не распознана)"


def test_speakers_uses_diarizer(tmp_path, audio):
    d = FakeDiarizer()
    e = engine(tmp_path, diarizer_factory=lambda: d)
    out = transcribe(e, {"path": str(audio), "speakers": True, "num_speakers": 2})
    assert out == "Спикер 1: привет\nСпикер 2: пока"
    assert d.num == 2


def test_speakers_without_pyannote_is_tool_error(tmp_path, audio):
    def missing():
        raise ToolError("разделение по спикерам недоступно")
    with pytest.raises(ToolError, match="недоступно"):
        transcribe(engine(tmp_path, diarizer_factory=missing),
                   {"path": str(audio), "speakers": True})


def test_gallery_only_when_identify_enabled(tmp_path, audio):
    calls = []
    e = engine(tmp_path, diarizer_factory=FakeDiarizer,
               gallery_loader=lambda: calls.append(1) or {})
    transcribe(e, {"path": str(audio), "speakers": True})
    assert calls == []
    e.cfg.identify = True
    transcribe(e, {"path": str(audio), "speakers": True})
    assert calls == [1]


# --- выгрузка по простою ------------------------------------------------------------

class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def test_models_unloaded_only_after_idle(tmp_path, audio):
    clock = Clock()
    made = []
    e = Engine(make_cfg(tmp_path), clock=clock,
               transcriber_factory=lambda: made.append(1) or FakeTranscriber())
    assert e.unload_if_idle(60) is None          # ничего не загружено
    transcribe(e, {"path": str(audio)})
    assert e.loaded == ["asr"]
    clock.now += 59
    assert e.unload_if_idle(60) is None
    clock.now += 2
    assert e.unload_if_idle(60) == "unloaded"
    assert e.loaded == []
    transcribe(e, {"path": str(audio)})
    assert made == [1, 1]                         # загрузилась заново


def test_diarizer_unload_asks_for_recycle(tmp_path, audio):
    clock = Clock()
    e = engine(tmp_path, diarizer_factory=FakeDiarizer, clock=clock)
    transcribe(e, {"path": str(audio), "speakers": True})
    assert e.loaded == ["asr", "diarization"]
    clock.now += 100
    assert e.unload_if_idle(60) == "recycle"


def test_unload_does_not_interrupt_running_call(tmp_path, audio):
    clock = Clock()
    started, release = threading.Event(), threading.Event()

    class Slow(FakeTranscriber):
        def transcribe(self, path):
            started.set()
            release.wait(5)
            return super().transcribe(path)

    e = engine(tmp_path, Slow(), clock=clock)
    e.transcriber()
    th = threading.Thread(target=transcribe, args=(e, {"path": str(audio)}))
    th.start()
    started.wait(5)
    clock.now += 1000
    assert e.unload_if_idle(60) is None
    release.set()
    th.join(5)
    assert e.loaded == ["asr"]


# --- архив транскриптов -------------------------------------------------------------

@pytest.fixture
def archive(tmp_path):
    out = tmp_path / "out"
    for period, base, text, age in [("2026-09", "2026-09-30_10-00-00", "старая", 300),
                                    ("2026-10", "2026-10-07_14-03-11", "планёрка", 100),
                                    ("2026-10", "Пример записи", "цели", 10)]:
        d = out / period
        d.mkdir(parents=True, exist_ok=True)
        for ext in (".txt", ".srt"):
            p = d / f"{base}{ext}"
            p.write_text(f"[00:00:00] {text}{ext}\n", encoding="utf-8")
            t = time.time() - age
            os.utime(p, (t, t))
    (out / "2026-10" / "Пример записи.speakers.json").write_text("{}")
    return out


def test_list_transcripts_newest_first(tmp_path, archive):
    out = list_transcripts(engine(tmp_path), {})
    ids = [line.split("\t")[0] for line in out.splitlines()[1:]]
    assert ids == ["2026-10/Пример записи", "2026-10/2026-10-07_14-03-11",
                   "2026-09/2026-09-30_10-00-00"]


def test_list_transcripts_query_and_limit(tmp_path, archive):
    e = engine(tmp_path)
    assert list_transcripts(e, {"query": "ПРИМЕР"}).splitlines()[1].startswith(
        "2026-10/Пример записи\t")
    out = list_transcripts(e, {"limit": 1})
    assert out.endswith("… ещё 2")
    assert list_transcripts(e, {"query": "нет такого"}) == "транскриптов не найдено"
    with pytest.raises(ToolError):
        list_transcripts(e, {"limit": 0})


def test_list_transcripts_without_archive(tmp_path):
    assert list_transcripts(engine(tmp_path), {}) == "транскриптов не найдено"


def test_get_transcript_by_id_and_by_name(tmp_path, archive):
    e = engine(tmp_path)
    assert get_transcript(e, {"id": "2026-10/2026-10-07_14-03-11"}) == "[00:00:00] планёрка.txt\n"
    assert get_transcript(e, {"id": "Пример записи", "format": "srt"}) == "[00:00:00] цели.srt\n"
    cut = get_transcript(e, {"id": "Пример записи", "max_chars": 5})
    assert cut.startswith("[00:0\n… [обрезано")


@pytest.mark.parametrize("ident", [
    "../2026-10/Пример записи", "2026-10/../../etc/passwd", "/etc/passwd", "..",
    "2026-10/..", "x\\..\\y", "", "2026-10/нет", "*",
])
def test_get_transcript_stays_inside_archive(tmp_path, archive, ident):
    (tmp_path / "secret.txt").write_text("секрет")
    with pytest.raises(ToolError):
        get_transcript(engine(tmp_path), {"id": ident})


def test_get_transcript_refuses_symlink_out(tmp_path, archive):
    (tmp_path / "secret.txt").write_text("секрет")
    (archive / "2026-10" / "ссылка.txt").symlink_to(tmp_path / "secret.txt")
    with pytest.raises(ToolError, match="не найден"):
        get_transcript(engine(tmp_path), {"id": "2026-10/ссылка"})


def test_status_counts(tmp_path, archive, audio):
    e = engine(tmp_path)
    (tmp_path / "inbox").mkdir()
    (tmp_path / "inbox" / "rec.m4a").write_bytes(b"x")
    out = status(e, {})
    assert "модели в памяти: нет" in out
    assert "ждут обработки в inbox: 1" in out
    assert "транскриптов в архиве: 3" in out
    transcribe(e, {"path": str(audio)})
    assert "модели в памяти: asr" in status(e, {})


# --- протокол -----------------------------------------------------------------------

def req(rid, method, params=None):
    return {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}


def test_initialize_negotiates_version(tmp_path):
    s = Server(engine(tmp_path), TOOLS)
    r = s.respond(req(1, "initialize", {"protocolVersion": "2025-06-18"}))
    assert r["result"]["protocolVersion"] == "2025-06-18"
    assert r["result"]["capabilities"] == {"tools": {}}
    r = s.respond(req(2, "initialize", {"protocolVersion": "1999-01-01"}))
    assert r["result"]["protocolVersion"] == protocol.PROTOCOLS[0]


def test_tools_list(tmp_path):
    r = Server(engine(tmp_path), TOOLS).respond(req(1, "tools/list"))
    tools = {t["name"]: t for t in r["result"]["tools"]}
    assert list(tools) == ["transcribe", "list_transcripts", "get_transcript", "status"]
    assert tools["get_transcript"]["inputSchema"]["required"] == ["id"]
    assert all(t["annotations"]["readOnlyHint"] for t in tools.values())


def test_tool_errors_are_results(tmp_path):
    s = Server(engine(tmp_path, FakeTranscriber(error=RuntimeError("Metal OOM"))), TOOLS)
    bad = s.respond(req(1, "tools/call", {"name": "transcribe",
                                          "arguments": {"path": "/no/such.ogg"}}))
    assert bad["result"]["isError"] is True
    assert "не найден" in bad["result"]["content"][0]["text"]


def test_model_crash_is_result(tmp_path, audio):
    s = Server(engine(tmp_path, FakeTranscriber(error=RuntimeError("Metal OOM"))), TOOLS)
    r = s.respond(req(1, "tools/call", {"name": "transcribe",
                                        "arguments": {"path": str(audio)}}))
    assert r["result"]["isError"] is True
    assert "Metal OOM" in r["result"]["content"][0]["text"]


def test_rpc_errors(tmp_path):
    s = Server(engine(tmp_path), TOOLS)
    assert s.respond(req(1, "resources/list"))["error"]["code"] == -32601
    assert s.respond(req(2, "tools/call", {"name": "rm"}))["error"]["code"] == -32602
    assert s.respond(req(3, "tools/call", {"name": "status", "arguments": [1]}))[
        "error"]["code"] == -32602
    assert s.respond([1, 2])["error"]["code"] == -32600
    assert s.respond({"jsonrpc": "2.0", "method": "notifications/initialized"}) is None


def test_stdio_cancelled_request_gets_no_reply(tmp_path, audio):
    out = io.StringIO()
    loop = StdioLoop(Server(engine(tmp_path), TOOLS), out)
    for m in [{"jsonrpc": "2.0", "method": "notifications/cancelled",
               "params": {"requestId": 7}},
              req(7, "tools/call", {"name": "transcribe", "arguments": {"path": str(audio)}}),
              req(8, "tools/call", {"name": "transcribe", "arguments": {"path": str(audio)}}),
              "{not json"]:
        loop.handle_line(m if isinstance(m, str) else json.dumps(m))
    loop.close()
    replies = [json.loads(x) for x in out.getvalue().splitlines()]
    assert sorted(str(m.get("id")) for m in replies) == ["8", "None"]


# --- HTTP ---------------------------------------------------------------------------

@pytest.fixture
def http(tmp_path, audio):
    httpd = make_http_server(Server(engine(tmp_path), TOOLS), TOKEN, port=0)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}/mcp"
    httpd.shutdown()
    httpd.server_close()


def post(url, body, headers=None, method="POST"):
    h = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json",
         "Accept": "application/json, text/event-stream", **(headers or {})}
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, json.loads(raw) if raw else None


def test_http_call_and_notification(http, audio):
    code, body = post(http, req(1, "initialize", {"protocolVersion": "2025-06-18"}))
    assert code == 200 and body["result"]["serverInfo"]["name"] == "mlaud"
    assert post(http, {"jsonrpc": "2.0", "method": "notifications/initialized"}) == (202, None)
    code, body = post(http, req(2, "tools/call", {"name": "transcribe",
                                                  "arguments": {"path": str(audio)}}))
    assert body["result"]["content"][0]["text"] == "привет как дела"


def test_http_requires_token(http):
    assert post(http, req(1, "ping"), {"Authorization": "Bearer wrong"})[0] == 401
    assert post(http, req(1, "ping"), {"Authorization": ""})[0] == 401


def test_http_rejects_foreign_origin(http):
    assert post(http, req(1, "ping"), {"Origin": "https://evil.example"})[0] == 403
    assert post(http, req(1, "ping"), {"Origin": "http://localhost:3000"})[0] == 200


def test_http_lenient_without_accept_header(http):
    assert post(http, req(1, "ping"), {"Accept": "*/*"}) == (
        200, {"jsonrpc": "2.0", "id": 1, "result": {}})


def test_http_get_delete_and_wrong_path(http):
    assert post(http, None, method="GET")[0] == 405
    assert post(http, None, method="DELETE")[0] == 405
    assert post(http.replace("/mcp", "/other"), req(1, "ping"))[0] == 404


def test_http_garbage_body(http):
    r = urllib.request.Request(http, data=b"{oops", method="POST",
                               headers={"Authorization": f"Bearer {TOKEN}"})
    with pytest.raises(urllib.error.HTTPError) as e:
        urllib.request.urlopen(r, timeout=10)
    assert e.value.code == 400


# --- процесс ------------------------------------------------------------------------

def _spawn(tmp_path, env_extra):
    env = {**os.environ, "PYTHONPATH": str(WORKER_DIR), "MLAUD_SERVICE": str(tmp_path),
           "MLAUD_OUTPUT": str(tmp_path / "out"), **env_extra}
    return subprocess.Popen([sys.executable, "-m", "mlaud_worker.mcp", "--http"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, env=env, cwd=tmp_path)


def test_http_process_ready_and_exits_on_stdin_eof(tmp_path):
    p = _spawn(tmp_path, {"MLAUD_MCP_TOKEN": TOKEN, "MLAUD_MCP_PORT": "0"})
    ready = json.loads(p.stdout.readline())
    assert ready["t"] == "ready" and ready["port"] > 0
    url = f"http://127.0.0.1:{ready['port']}/mcp"
    assert post(url, req(1, "tools/call", {"name": "status"}))[1]["result"]["isError"] is False
    p.stdin.close()                      # приложение умерло — труба закрылась
    assert p.wait(10) == 0
    with pytest.raises(urllib.error.URLError):
        post(url, req(2, "ping"))


def test_http_process_refuses_short_token(tmp_path):
    p = _spawn(tmp_path, {"MLAUD_MCP_TOKEN": "short", "MLAUD_MCP_PORT": "0"})
    out, _ = p.communicate(timeout=10)
    assert p.returncode == 2
    assert json.loads(out)["t"] == "error"


def test_http_process_reports_busy_port(tmp_path):
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen()
    try:
        p = _spawn(tmp_path, {"MLAUD_MCP_TOKEN": TOKEN,
                              "MLAUD_MCP_PORT": str(s.getsockname()[1])})
        out, _ = p.communicate(timeout=10)
        assert p.returncode == 2
        msg = json.loads(out)
        assert msg["t"] == "error" and "занят" in msg["message"]
    finally:
        s.close()


def test_stdio_process_keeps_stdout_clean(tmp_path):
    """В stdout только JSON-RPC, даже если инструмент печатает (в том числе из C)."""
    code = ("import os, sys\n"
            "from mlaud_worker.mcp import tools\n"
            "real = tools.status\n"
            "def noisy(engine, args):\n"
            "    print('python noise')\n"
            "    os.write(1, b'C-level noise\\n')\n"
            "    return real(engine, args)\n"
            "for t in tools.TOOLS:\n"
            "    if t.name == 'status': t.handler = noisy\n"
            "from mlaud_worker.mcp.__main__ import main\n"
            "sys.exit(main([]))")
    msgs = [req(1, "initialize", {"protocolVersion": "2025-06-18"}),
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            req(2, "tools/call", {"name": "status"})]
    env = {**os.environ, "PYTHONPATH": str(WORKER_DIR), "MLAUD_SERVICE": str(tmp_path)}
    p = subprocess.run([sys.executable, "-c", code],
                       input="\n".join(map(json.dumps, msgs)) + "\n",
                       capture_output=True, text=True, timeout=60, env=env, cwd=tmp_path)
    assert p.returncode == 0, p.stderr
    replies = [json.loads(x) for x in p.stdout.splitlines()]
    assert [m["id"] for m in replies] == [1, 2]
    assert "python noise" in p.stderr and "C-level noise" in p.stderr
