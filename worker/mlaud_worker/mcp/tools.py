"""Инструменты MCP MLaud и общее состояние процесса (модели, настройки).

Модели грузятся при первом вызове и выгружаются после простоя: процесс живёт, пока
работает приложение, а 1.5 ГБ должны быть заняты, только пока ими пользуются.
"""

import base64
import gc
import json
import os
import re
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

from .protocol import Tool, ToolError, log

MAX_BASE64_BYTES = 100 * 1024 * 1024
FORMATS = ("text", "timestamps", "srt", "segments")
_ID = re.compile(r"^(?:(\d{4}-\d{2})/)?([^/\\]+)$")


class Engine:
    """Модели и настройки процесса. Распознавание идёт по одному вызову за раз."""

    def __init__(self, cfg, transcriber_factory=None, diarizer_factory=None,
                 gallery_loader=None, clock=time.monotonic):
        self.cfg = cfg
        self._transcriber_factory = transcriber_factory or self._default_transcriber
        self._diarizer_factory = diarizer_factory or self._default_diarizer
        self._gallery_loader = gallery_loader or self._default_gallery
        self._transcriber = None
        self._diarizer = None
        self._lock = threading.Lock()
        self._clock = clock
        self.last_used = clock()

    # --- модели -----------------------------------------------------------------------

    @contextmanager
    def using(self):
        with self._lock:
            try:
                yield
            finally:
                self.last_used = self._clock()

    @property
    def loaded(self) -> list[str]:
        return [n for n, m in (("asr", self._transcriber), ("diarization", self._diarizer))
                if m is not None]

    def transcriber(self):
        if self._transcriber is None:
            self._transcriber = self._transcriber_factory()
        return self._transcriber

    def diarizer(self):
        if self._diarizer is None:
            self._diarizer = self._diarizer_factory()
        return self._diarizer

    def unload_if_idle(self, idle_sec: float) -> str | None:
        """Выгрузить простаивающие модели; идущий вызов не ждёт.

        "recycle" — выгружена диаризация: драйвер MPS у torch держит гигабайты и после
        empty_cache, вернуть их системе может только новый процесс."""
        if not self.loaded or not self._lock.acquire(blocking=False):
            return None
        try:
            if self._clock() - self.last_used < idle_sec:
                return None
            had_torch = self._diarizer is not None
            self._transcriber = None
            self._diarizer = None
            _release_memory()
            return "recycle" if had_torch else "unloaded"
        finally:
            self._lock.release()

    def start_reaper(self, idle_sec: float, on_recycle=None) -> threading.Thread:
        def loop():
            while True:
                time.sleep(min(30.0, max(1.0, idle_sec / 4)))
                done = self.unload_if_idle(idle_sec)
                if done:
                    log(f"модели выгружены после {idle_sec:.0f} с простоя")
                if done == "recycle" and on_recycle is not None:
                    on_recycle()
        t = threading.Thread(target=loop, name="mlaud-mcp-reaper", daemon=True)
        t.start()
        return t

    def _default_transcriber(self):
        from ..transcribe import Transcriber
        return Transcriber(model_type=self.cfg.model_type)

    def _default_diarizer(self):
        try:
            import pyannote.audio  # noqa: F401 — проверить наличие до загрузки модели
            from ..diarize import Diarizer
        except ImportError as e:
            raise ToolError("разделение по спикерам недоступно: в этом окружении нет "
                            f"pyannote ({e.name})") from e
        return Diarizer(hf_token=self.cfg.hf_token or None,
                        device=self.cfg.diarize_device or "cpu")

    def _default_gallery(self):
        from ..voices import VoiceStore
        return VoiceStore(self.cfg.voices_dir).gallery()

    def gallery(self):
        """База голосов — только если пользователь включил идентификацию."""
        if not self.cfg.identify:
            return None
        try:
            return self._gallery_loader()
        except Exception as e:  # noqa: BLE001 — имена опциональны, текст важнее
            log(f"база голосов не прочитана: {e}")
            return None


def _release_memory() -> None:
    gc.collect()
    if "mlx.core" in sys.modules:
        sys.modules["mlx.core"].clear_cache()
    torch = sys.modules.get("torch")
    if torch is not None and torch.backends.mps.is_available():
        torch.mps.empty_cache()


# --- transcribe -------------------------------------------------------------------------

def _check_file(path: Path) -> None:
    if not path.is_absolute():
        raise ToolError(f"нужен абсолютный путь: {path}")
    if not path.is_file():
        raise ToolError(f"файл не найден: {path}")
    st = path.stat()
    if st.st_size == 0:
        raise ToolError(f"файл пустой: {path}")
    if st.st_size > 4096 and getattr(st, "st_blocks", 1) == 0:
        raise ToolError(f"файл выгружен в iCloud и не скачан на этот Mac: {path}")


def render(segments: list[dict], fmt: str) -> str:
    from ..output import _with_speaker, build_srt, build_txt

    if fmt == "timestamps":
        return build_txt(segments)
    if fmt == "srt":
        return build_srt(segments)
    if fmt == "segments":
        return json.dumps(
            [{"start": round(s["start"], 2), "end": round(s["end"], 2),
              "text": s["text"].strip(),
              **({"speaker": s["speaker"]} if s.get("speaker") else {})}
             for s in segments if s["text"].strip()],
            ensure_ascii=False, indent=1)
    texts = [_with_speaker(s) for s in segments if s["text"].strip()]
    return ("\n" if any(s.get("speaker") for s in segments) else " ").join(texts)


def transcribe(engine: Engine, args: dict) -> str:
    fmt = args.get("format") or "text"
    if fmt not in FORMATS:
        raise ToolError(f"format: одно из {', '.join(FORMATS)}")
    path_arg, b64 = args.get("path"), args.get("audio_base64")
    if bool(path_arg) == bool(b64):
        raise ToolError("укажи ровно одно из: path или audio_base64")
    speakers = bool(args.get("speakers"))
    num = args.get("num_speakers")
    if num is not None and (not isinstance(num, int) or isinstance(num, bool) or num < 1):
        raise ToolError("num_speakers: целое число ≥ 1")

    tmp = None
    try:
        if b64:
            tmp = _materialize(b64, args.get("filename") or "audio")
            path = tmp
        else:
            path = Path(os.path.expanduser(str(path_arg)))
            _check_file(path)
        from ..audio import AudioDecodeError
        from ..pipeline import analyze

        with engine.using():
            cfg = engine.cfg
            cfg.num_speakers = num or 0
            diarizer = engine.diarizer() if speakers else None
            try:
                result = analyze(path, cfg, engine.transcriber(), diarizer,
                                 engine.gallery() if speakers else None)
            except AudioDecodeError as e:
                raise ToolError(f"не удалось декодировать аудио ({path.suffix or 'без '
                                'расширения'}): {e}") from e
        text = render(result.segments, fmt)
        return text if text.strip() else "(речь не распознана)"
    finally:
        if tmp is not None:
            tmp.unlink(missing_ok=True)
            tmp.parent.rmdir()


def _materialize(b64: str, filename: str) -> Path:
    """base64 → временный файл с исходным расширением (по нему afconvert выбирает формат)."""
    if len(b64) > MAX_BASE64_BYTES * 4 // 3 + 4:
        raise ToolError(f"audio_base64 больше {MAX_BASE64_BYTES // (1024 * 1024)} МБ — "
                        "передай путь к файлу")
    try:
        data = base64.b64decode(b64, validate=True)
    except ValueError as e:
        raise ToolError(f"audio_base64 не является base64: {e}") from e
    if not data:
        raise ToolError("audio_base64 пустой")
    suffix = Path(filename).suffix.lower()
    if not suffix or not suffix[1:].isalnum():
        suffix = ""
    d = Path(tempfile.mkdtemp(prefix="mlaud-asr-"))
    p = d / f"audio{suffix}"
    p.write_bytes(data)
    return p


# --- архив транскриптов -------------------------------------------------------------------

def _transcripts(cfg) -> list[Path]:
    root = cfg.output
    if not root.is_dir():
        return []
    files = [p for p in root.glob("*/*.txt") if p.is_file() and not p.name.startswith(".")]
    return sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)


def _transcript_id(cfg, p: Path) -> str:
    return f"{p.parent.name}/{p.stem}"


def list_transcripts(engine: Engine, args: dict) -> str:
    limit = args.get("limit", 20)
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 500:
        raise ToolError("limit: целое число от 1 до 500")
    query = (args.get("query") or "").strip().lower()
    files = _transcripts(engine.cfg)
    if query:
        files = [p for p in files if query in p.stem.lower()]
    if not files:
        return "транскриптов не найдено"
    lines = []
    for p in files[:limit]:
        st = p.stat()
        when = datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")
        lines.append(f"{_transcript_id(engine.cfg, p)}\t{when}\t{st.st_size // 1024 + 1} КБ")
    more = len(files) - limit
    tail = f"\n… ещё {more}" if more > 0 else ""
    return "id\tготов\tразмер\n" + "\n".join(lines) + tail


def _resolve_transcript(cfg, ident: str, suffix: str) -> Path:
    m = _ID.match(ident or "")
    if not m or m.group(2) in (".", ".."):
        raise ToolError("id: «ГГГГ-ММ/имя» из list_transcripts или просто имя записи")
    period, base = m.groups()
    root = cfg.output.resolve()
    if period:
        candidates = [cfg.output / period / f"{base}{suffix}"]
    else:
        candidates = sorted(cfg.output.glob(f"*/{_glob_escape(base)}{suffix}"), reverse=True)
    for c in candidates:
        try:
            real = c.resolve(strict=True)
        except OSError:
            continue
        if real.is_file() and real.is_relative_to(root):
            return real
    raise ToolError(f"транскрипт не найден: {ident}")


def _glob_escape(s: str) -> str:
    return re.sub(r"([*?\[])", r"[\1]", s)


def get_transcript(engine: Engine, args: dict) -> str:
    fmt = args.get("format") or "txt"
    if fmt not in ("txt", "srt"):
        raise ToolError("format: txt или srt")
    max_chars = args.get("max_chars")
    if max_chars is not None and (not isinstance(max_chars, int) or isinstance(max_chars, bool)
                                  or max_chars < 1):
        raise ToolError("max_chars: целое число ≥ 1")
    path = _resolve_transcript(engine.cfg, args.get("id"), "." + fmt)
    text = path.read_text(encoding="utf-8", errors="replace")
    if max_chars and len(text) > max_chars:
        return text[:max_chars] + f"\n… [обрезано: показано {max_chars} из {len(text)} символов]"
    return text if text.strip() else "(транскрипт пустой: речь не распознана)"


# --- статус -------------------------------------------------------------------------------

def status(engine: Engine, args: dict) -> str:
    from .. import delivery_queue
    from ..pipeline import list_audio

    cfg = engine.cfg
    lines = [f"модели в памяти: {', '.join(engine.loaded) or 'нет (загрузятся при вызове)'}"]
    try:
        lines.append(f"ждут обработки в inbox: {len(list_audio(cfg))}")
    except OSError as e:
        lines.append(f"inbox недоступен: {e}")
    lines.append(f"не доставлено в Telegram: {len(delivery_queue.pending_bases(cfg))}")
    lines.append(f"транскриптов в архиве: {len(_transcripts(cfg))}")
    lines.append(f"разделение по спикерам: {'включено' if cfg.diarize else 'выключено'}"
                 f", имена по голосу: {'да' if cfg.diarize and cfg.identify else 'нет'}")
    return "\n".join(lines)


TOOLS = [
    Tool(
        name="transcribe",
        title="Распознать речь в аудиофайле",
        description=(
            "Локальное распознавание речи (GigaAM v3, русский язык) на этом Mac. "
            "Принимает голосовые Telegram (.ogg/.oga, Opus), видеокружки (.mp4), mp3, m4a, "
            "wav, aac, flac, aiff, caf. Передай абсолютный путь в `path` или содержимое "
            "файла в `audio_base64` с `filename`. Возвращает текст. Запись не сохраняется "
            "в архив MLaud и не отправляется в Niti."
        ),
        handler=transcribe,
        properties={
            "path": {"type": "string", "description": "Абсолютный путь к аудиофайлу."},
            "audio_base64": {"type": "string",
                             "description": "Содержимое файла в base64, если пути нет."},
            "filename": {"type": "string",
                         "description": "Имя файла для audio_base64; по расширению "
                                        "определяется формат, например voice.ogg."},
            "format": {"type": "string", "enum": list(FORMATS), "default": "text",
                       "description": "text — сплошной текст; timestamps — строки "
                                      "[ЧЧ:ММ:СС]; srt — субтитры; segments — JSON."},
            "speakers": {"type": "boolean", "default": False,
                         "description": "Разделить по спикерам (медленнее, для записей "
                                        "встреч)."},
            "num_speakers": {"type": "integer", "minimum": 1,
                             "description": "Число спикеров, если известно."},
        },
    ),
    Tool(
        name="list_transcripts",
        title="Список транскриптов MLaud",
        description="Готовые транскрипты записей из архива MLaud, новые сверху. "
                    "id из списка передаётся в get_transcript.",
        handler=list_transcripts,
        properties={
            "query": {"type": "string", "description": "Подстрока в имени записи."},
            "limit": {"type": "integer", "minimum": 1, "maximum": 500, "default": 20},
        },
    ),
    Tool(
        name="get_transcript",
        title="Текст транскрипта MLaud",
        description="Текст транскрипта записи из архива MLaud по id из list_transcripts.",
        handler=get_transcript,
        properties={
            "id": {"type": "string", "description": "«ГГГГ-ММ/имя» или имя записи."},
            "format": {"type": "string", "enum": ["txt", "srt"], "default": "txt"},
            "max_chars": {"type": "integer", "minimum": 1,
                          "description": "Обрезать длинный транскрипт."},
        },
        required=["id"],
    ),
    Tool(
        name="status",
        title="Состояние MLaud",
        description="Что сейчас делает MLaud: модели в памяти, очередь inbox, "
                    "недоставленное, число транскриптов.",
        handler=status,
    ),
]
