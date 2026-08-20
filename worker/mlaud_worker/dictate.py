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
"""

import base64
import json
import os
import sys
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
    """

    def __init__(self, decode: Callable[[np.ndarray], str],
                 decode_every_sec: float = DECODE_EVERY_SEC,
                 max_window_sec: float = MAX_WINDOW_SEC,
                 sr: int = SR,
                 tracker: Optional[CommitTracker] = None,
                 vad: Optional[SilenceDetector] = None):
        self.decode = decode
        self.decode_every = int(decode_every_sec * sr)
        self.max_window = int(max_window_sec * sr)
        self.sr = sr
        self.tracker = tracker or CommitTracker()
        self.vad = vad if vad is not None else SilenceDetector(sr=sr)
        self._window = np.zeros(0, dtype=np.float32)
        self._undecoded = 0
        self._decodes = 0

    def feed(self, samples: np.ndarray) -> list[dict]:
        """Добавить кусок звука. Вернуть события для отправки наверх."""
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

        if self._undecoded >= self.decode_every:
            self._undecoded = 0
            self._decodes += 1
            text = self.decode(self._window)
            committed = self.tracker.update(text)
            if committed:
                events.append({"t": "commit", "text": committed})
            events.append({"t": "preview", "text": self.tracker.preview()})
        return events

    def flush(self, reason: str = "manual") -> list[dict]:
        """Досказать всё до конца и начать новое окно."""
        events: list[dict] = []
        if self._window.size:
            window_sec = round(self._window.size / self.sr, 1)
            decodes = self._decodes
            rest = self.tracker.finalize(self.decode(self._window))
            if rest:
                events.append({"t": "commit", "text": rest})
                events.append({"t": "preview", "text": ""})
            events.append({"t": "stat", "reason": reason,
                           "window_sec": window_sec, "decodes": decodes})
        self.reset()
        return events

    def reset(self) -> None:
        self._window = np.zeros(0, dtype=np.float32)
        self._undecoded = 0
        self._decodes = 0
        self.tracker.reset()
        self.vad.reset()


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

    session = DictationSession(decode)
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
        kind = msg.get("t")
        if kind == "quit":
            break
        try:
            if kind == "audio":
                samples = pcm16_to_float32(base64.b64decode(msg.get("pcm", "")))
                for ev in session.feed(samples):
                    _emit(ev, stdout)
            elif kind == "flush":
                for ev in session.flush():
                    _emit(ev, stdout)
            elif kind == "reset":
                session.reset()
            else:
                _emit({"t": "error", "message": f"неизвестная команда: {kind}"}, stdout)
        except Exception as e:  # noqa: BLE001 — один сбойный кадр не роняет сессию
            _emit({"t": "error", "message": str(e)}, stdout)
    return 0


if __name__ == "__main__":
    # Ту же модель, что выбрана в настройках приложения: иначе диктовка молча
    # работала бы на rnnt, когда для файлов выбран ctc.
    raise SystemExit(serve(model_type=os.environ.get("MLAUD_MODEL") or "rnnt"))
