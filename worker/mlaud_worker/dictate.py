"""Диктовка: резидентный процесс, который держит модель в памяти и расшифровывает
поток с микрофона по мере поступления.

Почему отдельный процесс, а не режим пакетного worker'а: тот эфемерный — поднялся,
разобрал inbox, умер. Для диктовки модель должна быть уже загружена (1.8 с и ~1.6 ГБ
RSS), иначе первое слово ждёт две секунды.

Протокол — JSON-строки в обе стороны, аудио внутри base64 (int16, 16 кГц, mono).
Двоичный кадр был бы экономнее, но 32 КБ/с речи превращаются в 43 КБ/с base64 —
на фоне расшифровки это ничто, зато поток читается глазами и тестируется без Swift.

  ← {"t":"audio","pcm":"<base64 int16>"}   поток с микрофона
  ← {"t":"flush"}                          конец фразы: докоммитить всё
  ← {"t":"reset"}                          выбросить накопленное
  ← {"t":"quit"}
  → {"t":"ready"}                          модель загружена, можно говорить
  → {"t":"commit","text":"…"}              текст устоялся, его можно печатать
  → {"t":"preview","text":"…"}             хвост ещё может перепишаться
  → {"t":"error","message":"…"}
  → {"t":"stat","reason":"silence|overflow","window_sec":…,"decodes":…}

Каналы живого звонка (docs/feature-prompter.md §5.1). Форма событий фиксируется
при создании сессии: команда без `ch` — сессия `main`, события как выше, байт в байт;
команда с `ch` — канальная сессия, события несут `ch` и номер фразы, вместо `stat` —
`phrase`. Канал `main` зарезервирован за диктовкой и отвергается.

  ← {"t":"open","ch":"them","label":"Собеседник"}   свои VAD, трекер, счётчики; повторный open — заново
  ← {"t":"audio","ch":"them","pcm":"…"}             без open — канал создаётся сам
  ← {"t":"flush","ch":"them"}                        закрыть фразу, reason "flush"
  ← {"t":"reset","ch":"them"}                        выбросить окно; received и phrase не трогаются
  ← {"t":"close","ch":"them"}                        flush + удалить канал; quit каналы НЕ закрывает
  → {"t":"commit","ch":"them","phrase":12,"text":"…"}
  → {"t":"preview","ch":"them","phrase":12,"text":"…"}
  → {"t":"phrase","ch":"them","phrase":12,"t0":183.2,"t1":190.6,"text":"…",
     "reason":"silence|overflow|flush","window_sec":7.4,"decodes":18}
  → {"t":"error","ch":"them","message":"…"}          ch — если был в команде

`t0`/`t1` — секунды принятого звука канала от `open` (включая тишину), не wall-clock.
`text` в `phrase` — финальный разбор всего окна; `commit` при закрытии несёт только хвост.
Канальные сессии несут сторож отставания (poc/live2ch/RESULT.md:66-69): если разбор
отстал от принятого звука больше чем на `max_lag_sec`, периодический переразбор
пропускается, пока не догоним; VAD и закрытие фраз работают как обычно.
"""

import base64
import functools
import json
import os
import sys
import time
from typing import Callable, Optional

import numpy as np

SR = 16000
DECODE_EVERY_SEC = 0.4      # как часто переразбирать растущее окно
MAX_WINDOW_SEC = 18.0       # gigaam режет на 20-сек чанки; до этого не доводим
SILENCE_RMS = 0.006         # порог тишины по RMS (float32 -1..1)
SILENCE_HOLD_SEC = 0.8      # столько тишины подряд = конец фразы


def _common_prefix(variants: list[list[str]]) -> list[str]:
    """Самый длинный общий префикс нескольких разборов (по словам)."""
    if not variants:
        return []
    out: list[str] = []
    for i in range(min(len(v) for v in variants)):
        w = variants[0][i]
        if all(v[i] == w for v in variants[1:]):
            out.append(w)
        else:
            break
    return out


class CommitTracker:
    """Решает, какие слова уже можно печатать, а какие ещё перепишутся.

    Растущее окно RNNT переразбирается целиком, и хвост при этом пляшет: на замере
    'Просто' на первой секунде превратилось в 'Так, погнали.' на четвёртой. Но глубже
    последнего слова правки не заходили — поэтому коммитим то, что совпало в
    последних `stability` разборах, и всегда придерживаем `tail_hold` слов с конца.
    """

    def __init__(self, stability: int = 2, tail_hold: int = 1):
        self.stability = stability
        self.tail_hold = tail_hold
        self._recent: list[list[str]] = []
        self._emitted = 0

    def update(self, text: str) -> str:
        """Скормить очередной разбор окна. Вернуть текст, который стал окончательным."""
        words = text.split()
        self._recent.append(words)
        if len(self._recent) > self.stability:
            self._recent.pop(0)
        if len(self._recent) < self.stability:
            return ""
        stable = _common_prefix(self._recent)
        limit = max(0, len(stable) - self.tail_hold)
        if limit <= self._emitted:
            return ""
        fresh = stable[self._emitted:limit]
        self._emitted = limit
        return " ".join(fresh)

    def preview(self) -> str:
        """Незакоммиченный хвост последнего разбора — для подсказки на экране."""
        if not self._recent:
            return ""
        return " ".join(self._recent[-1][self._emitted:])

    def finalize(self, text: str) -> str:
        """Конец фразы: последний разбор считаем окончательным.

        Отдаём хвост, который ещё не напечатан, и начинаем с чистого листа.
        Допущение то же, на котором стоит весь коммит: правки не заходят глубже
        последнего слова, поэтому уже напечатанный префикс финальный разбор
        подтверждает, а не переписывает.
        """
        rest = " ".join(text.split()[self._emitted:])
        self.reset()
        return rest

    def reset(self) -> None:
        self._recent = []
        self._emitted = 0


class SilenceDetector:
    """Простейший VAD по энергии: копит длительность тишины подряд."""

    def __init__(self, rms_threshold: float = SILENCE_RMS,
                 hold_sec: float = SILENCE_HOLD_SEC, sr: int = SR):
        self.rms_threshold = rms_threshold
        self.hold_sec = hold_sec
        self.sr = sr
        self._silent_sec = 0.0
        self._had_speech = False

    def feed(self, samples: np.ndarray) -> bool:
        """True, если фраза закончилась (была речь, потом достаточно тишины)."""
        if samples.size == 0:
            return False
        rms = float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))
        dur = samples.size / self.sr
        if rms < self.rms_threshold:
            self._silent_sec += dur
        else:
            self._silent_sec = 0.0
            self._had_speech = True
        if self._had_speech and self._silent_sec >= self.hold_sec:
            self.reset()
            return True
        return False

    def reset(self) -> None:
        self._silent_sec = 0.0
        self._had_speech = False


class DictationSession:
    """Окно аудио + трекер коммитов + VAD. Не знает ни про модель, ни про stdin.

    `decode` — функция (np.ndarray 16 кГц float32) -> str. В тестах подставляется
    заглушкой, в бою — gigaam.

    `ch=None` — унаследованная сессия диктовки: события без `ch`, `stat` при закрытии
    фразы. `ch` задан — канальная сессия звонка: события с `ch` и `phrase`, вместо
    `stat` — `phrase` с `t0`/`t1` по принятому звуку.
    """

    def __init__(self, decode: Callable[[np.ndarray], str],
                 decode_every_sec: float = DECODE_EVERY_SEC,
                 max_window_sec: float = MAX_WINDOW_SEC,
                 sr: int = SR,
                 tracker: Optional[CommitTracker] = None,
                 vad: Optional[SilenceDetector] = None,
                 *, ch: Optional[str] = None, label: Optional[str] = None,
                 clock: Callable[[], float] = time.monotonic,
                 max_lag_sec: Optional[float] = None,
                 voice=None):
        self.decode = decode
        self.decode_every = int(decode_every_sec * sr)
        self.max_window = int(max_window_sec * sr)
        self.sr = sr
        self.tracker = tracker or CommitTracker()
        self.vad = vad if vad is not None else SilenceDetector(sr=sr)
        self.ch = ch
        self.label = label
        self.clock = clock
        self.max_lag_sec = max_lag_sec
        self.voice = voice            # LiveVoice | None: пометка «Я / не я» в phrase (этап 5)
        self.received = 0           # сэмплов принято с создания; reset() не обнуляет
        self.phrase = 1             # номер открытой фразы; += 1 после события phrase
        self._t_first: Optional[float] = None
        self._window = np.zeros(0, dtype=np.float32)
        self._undecoded = 0
        self._decodes = 0

    def _event(self, kind: str, **fields) -> dict:
        """Событие наверх; канальная сессия добавляет ch и phrase сразу после t."""
        ev: dict = {"t": kind}
        if self.ch is not None:
            ev["ch"] = self.ch
            ev["phrase"] = self.phrase
        ev.update(fields)
        return ev

    def _behind(self) -> bool:
        """Сторож отставания: разбор отстал от принятого звука больше max_lag_sec."""
        if self.max_lag_sec is None or self._t_first is None:
            return False
        lag = (self.clock() - self._t_first) - self.received / self.sr
        return lag > self.max_lag_sec

    def feed(self, samples: np.ndarray) -> list[dict]:
        """Добавить кусок звука. Вернуть события для отправки наверх."""
        if self._t_first is None:
            self._t_first = self.clock()
        self.received += samples.size
        self._window = np.concatenate([self._window, samples])
        self._undecoded += samples.size
        events: list[dict] = []

        end_of_phrase = self.vad.feed(samples)
        overflow = self._window.size >= self.max_window
        if end_of_phrase or overflow:
            # Чем закрылась фраза — паузой или упором в предел окна. Разница важна:
            # если пауз не находится, окно всегда доходит до максимума и каждый разбор
            # стоит как самый дорогой, а текст приходит редкими кусками.
            events.extend(self.flush(reason="silence" if end_of_phrase else "overflow"))
            return events

        if self._undecoded >= self.decode_every and not self._behind():
            self._undecoded = 0
            self._decodes += 1
            text = self.decode(self._window)
            committed = self.tracker.update(text)
            if committed:
                events.append(self._event("commit", text=committed))
            events.append(self._event("preview", text=self.tracker.preview()))
        return events

    def flush(self, reason: str = "manual") -> list[dict]:
        """Досказать всё до конца и начать новое окно."""
        events: list[dict] = []
        if self._window.size:
            window_sec = round(self._window.size / self.sr, 1)
            decodes = self._decodes
            text = self.decode(self._window)
            rest = self.tracker.finalize(text)
            if rest:
                events.append(self._event("commit", text=rest))
                events.append(self._event("preview", text=""))
            if self.ch is None:
                events.append(self._event("stat", reason=reason,
                                          window_sec=window_sec, decodes=decodes))
            else:
                t0 = round((self.received - self._window.size) / self.sr, 2)
                t1 = round(self.received / self.sr, 2)
                phrase = self._event("phrase", t0=t0, t1=t1, text=text, reason=reason,
                                     window_sec=window_sec, decodes=decodes)
                if self.voice is not None and self._window.size:
                    mark = self.voice.mark(self._window)
                    if mark is not None:
                        phrase["voice"] = mark
                events.append(phrase)
                self.phrase += 1
        self.reset()
        return events

    def reset(self) -> None:
        self._window = np.zeros(0, dtype=np.float32)
        self._undecoded = 0
        self._decodes = 0
        self.tracker.reset()
        self.vad.reset()

    def close(self) -> list[dict]:
        """Канал закрывается клиентом: дорассказать всё, что накопилось."""
        return self.flush(reason="flush")


class ChannelRegistry:
    """Сессии по каналам над одним decode (poc/live2ch/run.py, S1).

    Команда без `ch` относится к сессии `main` — унаследованной диктовке. Команда
    с `ch` — к канальной сессии; `main` как явный `ch` отвергается, иначе диктовка
    получала бы события с `ch`.
    """

    MAIN = "main"

    def __init__(self, make_session, voice_loader=None):
        self._make = make_session
        self._voice_loader = voice_loader   # () -> LiveVoice | None; лениво, один раз
        self._voice = ...                   # загрузка при первом open с voice (этап 5)
        self._sessions: dict[str, DictationSession] = {}

    def _voice_for(self, ch, want: bool):
        """Маркер канала: без флага — None; с флагом — живой маркер или ошибка."""
        if not want:
            return None, []
        if self._voice is ...:
            if self._voice_loader is None:
                self._voice = None
            else:
                self._voice = self._voice_loader()
        if self._voice is None:
            return None, [self._error(ch, "нет персоны «Я» в базе голосов — живые пометки выключены (запишите голос в «Голосах»)")]
        return self._voice, []

    def session(self, ch: Optional[str]) -> DictationSession:
        """Сессия канала; создаётся лениво (для канала — с label = ch)."""
        key = self.MAIN if ch is None else ch
        s = self._sessions.get(key)
        if s is None:
            s = self._make(ch, ch)
            self._sessions[key] = s
        return s



    @staticmethod
    def _error(ch: Optional[str], message: str) -> dict:
        ev: dict = {"t": "error"}
        if ch is not None:
            ev["ch"] = ch
        ev["message"] = message
        return ev

    def handle(self, msg: dict) -> list[dict]:
        """Одна команда → события."""
        kind = msg.get("t")
        ch = msg.get("ch")
        if ch == self.MAIN:
            return [self._error(ch, "канал main зарезервирован")]
        if kind == "open":
            if ch is None:
                return [self._error(None, "open без ch")]
            voice, errors = self._voice_for(ch, bool(msg.get("voice")))
            if errors:
                return errors
            self._sessions[ch] = self._make(ch, msg.get("label") or ch, voice=voice)
            return []
        if kind == "audio":
            samples = pcm16_to_float32(base64.b64decode(msg.get("pcm", "")))
            return self.session(ch).feed(samples)
        if kind == "flush":
            s = self.session(ch)
            return s.flush() if ch is None else s.flush(reason="flush")
        if kind == "reset":
            self.session(ch).reset()
            return []
        if kind == "close" and ch is not None:
            s = self._sessions.pop(ch, None)
            return s.close() if s is not None else []
        return [self._error(ch, f"неизвестная команда: {kind}")]

    def close_all(self) -> list[dict]:
        """Закрыть все сессии (для тестов; serve на quit этого не делает)."""
        events: list[dict] = []
        for s in list(self._sessions.values()):
            events.extend(s.close())
        self._sessions.clear()
        return events


def pcm16_to_float32(raw: bytes) -> np.ndarray:
    """int16 LE → float32 -1..1."""
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def _build_decoder(model_type: str = "rnnt") -> Callable[[np.ndarray], str]:
    """Замыкание над загруженной моделью gigaam: массив → текст."""
    import mlx.core as mx
    from gigaam_mlx import load_model
    from gigaam_mlx.audio import compute_mel

    model, tokenizer = load_model(model_type=model_type)

    def decode(audio: np.ndarray) -> str:
        # Окно короче MAX_WINDOW_SEC, поэтому режем как gigaam (split_audio) не нужно —
        # разбираем одним чанком, это и есть вся экономия на задержке.
        mel = compute_mel(audio)
        encoded, seq_len = model.encode(mx.array(mel[np.newaxis]))
        mx.eval(encoded)
        return tokenizer.decode(model.decode(encoded, seq_len)).strip()

    return decode


def _emit(event: dict, out=None) -> None:
    stream = out or sys.stdout
    stream.write(json.dumps(event, ensure_ascii=False) + "\n")
    stream.flush()


def _make_session(decode: Callable[[np.ndarray], str], ch: Optional[str],
                  label: Optional[str], voice=None) -> DictationSession:
    """Сессия для serve: сторож отставания только у каналов, диктовка без изменений."""
    return DictationSession(decode, ch=ch, label=label, max_lag_sec=1.0 if ch else None,
                            voice=voice)


def _voice_loader():
    """Живой маркер из базы голосов (этап 5); каталог — как у воркера."""
    from pathlib import Path

    from . import livevoice

    root = Path(os.environ.get("MLAUD_VOICES_DIR") or Path.home() / "ASR/voices")
    return livevoice.load(root)


def serve(stdin=None, stdout=None, decode: Optional[Callable] = None,
          model_type: str = "rnnt") -> int:
    """Резидентный цикл: читает команды из stdin, пишет события в stdout."""
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    try:
        decode = decode or _build_decoder(model_type)
    except Exception as e:  # noqa: BLE001 — без модели смысла продолжать нет
        _emit({"t": "error", "message": str(e)}, stdout)
        return 1

    registry = ChannelRegistry(functools.partial(_make_session, decode),
                               voice_loader=_voice_loader)
    _emit({"t": "ready"}, stdout)

    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            _emit({"t": "error", "message": "не JSON"}, stdout)
            continue
        if not isinstance(msg, dict):
            _emit({"t": "error", "message": "не JSON-объект"}, stdout)
            continue
        if msg.get("t") == "quit":
            break
        try:
            for ev in registry.handle(msg):
                _emit(ev, stdout)
        except Exception as e:  # noqa: BLE001 — один сбойный кадр не роняет сессию
            _emit(ChannelRegistry._error(msg.get("ch"), str(e)), stdout)
    return 0


if __name__ == "__main__":
    # Ту же модель, что выбрана в настройках приложения: иначе диктовка молча
    # работала бы на rnnt, когда для файлов выбран ctc.
    raise SystemExit(serve(model_type=os.environ.get("MLAUD_MODEL") or "rnnt"))
