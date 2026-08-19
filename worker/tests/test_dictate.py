"""Диктовка: коммит устоявшегося префикса, VAD, протокол резидентного процесса."""

import base64
import io
import json

import numpy as np
import pytest

from mlaud_worker import dictate as d


# --- CommitTracker -------------------------------------------------------------

def test_commit_waits_for_stability():
    t = d.CommitTracker(stability=2, tail_hold=1)
    assert t.update("так погнали давайте") == ""      # первый разбор — ждём подтверждения
    assert t.update("так погнали давайте") == "так погнали"  # хвост придержан


def test_commit_does_not_emit_rewritten_tail():
    """Реальный случай с замера: 'Просто' на 1-й секунде стало 'Так, погнали.' на 4-й."""
    t = d.CommitTracker(stability=2, tail_hold=1)
    t.update("Просто")
    t.update("Просто")          # 'Просто' — единственное слово, tail_hold его держит
    assert t.update("Так, погнали.") == ""
    assert t.update("Так, погнали.") == "Так,"
    # ничего ошибочного напечатано не было
    assert t._emitted == 1


def test_commit_never_repeats_words():
    t = d.CommitTracker(stability=2, tail_hold=1)
    seen = []
    for text in ["раз два", "раз два три", "раз два три четыре", "раз два три четыре пять"]:
        seen.append(t.update(text))
        seen.append(t.update(text))
    words = " ".join(w for w in seen if w).split()
    assert words == ["раз", "два", "три", "четыре"]  # пятое придержано как хвост


def test_preview_is_the_uncommitted_tail():
    t = d.CommitTracker(stability=2, tail_hold=1)
    t.update("раз два три")
    t.update("раз два три")
    assert t.preview() == "три"


def test_finalize_gives_out_the_rest_and_resets():
    t = d.CommitTracker(stability=2, tail_hold=1)
    t.update("раз два три")
    t.update("раз два три")            # напечатано «раз два», «три» придержано
    assert t.finalize("раз два три") == "три"
    assert t.preview() == "" and t._emitted == 0


# --- SilenceDetector -----------------------------------------------------------

def _speech(sec, sr=16000):
    return (np.random.default_rng(0).normal(0, 0.2, int(sr * sec))).astype(np.float32)


def _silence(sec, sr=16000):
    return np.zeros(int(sr * sec), dtype=np.float32)


def test_silence_alone_is_not_end_of_phrase():
    v = d.SilenceDetector(hold_sec=0.8)
    assert v.feed(_silence(5.0)) is False  # человек ещё не начинал говорить


def test_speech_then_silence_ends_phrase():
    v = d.SilenceDetector(hold_sec=0.8)
    assert v.feed(_speech(1.0)) is False
    assert v.feed(_silence(0.5)) is False
    assert v.feed(_silence(0.5)) is True   # 1.0 с тишины подряд — фраза кончилась


def test_pause_shorter_than_hold_does_not_split():
    v = d.SilenceDetector(hold_sec=0.8)
    v.feed(_speech(1.0))
    assert v.feed(_silence(0.4)) is False
    assert v.feed(_speech(0.4)) is False   # заговорил снова — счётчик сброшен
    assert v.feed(_silence(0.5)) is False


# --- DictationSession ----------------------------------------------------------

class FakeDecoder:
    """Отдаёт заранее заданный текст в зависимости от длины окна."""

    def __init__(self, by_seconds: dict):
        self.by_seconds = by_seconds
        self.calls = 0

    def __call__(self, audio):
        self.calls += 1
        sec = round(audio.size / 16000, 1)
        best = max((k for k in self.by_seconds if k <= sec + 1e-6), default=None)
        return self.by_seconds[best] if best is not None else ""


def test_session_commits_as_window_grows():
    dec = FakeDecoder({0.4: "раз", 0.8: "раз два", 1.2: "раз два три", 1.6: "раз два три четыре"})
    s = d.DictationSession(dec, decode_every_sec=0.4, vad=d.SilenceDetector(hold_sec=99))
    committed = []
    for _ in range(4):
        for ev in s.feed(_speech(0.4)):
            if ev["t"] == "commit":
                committed.append(ev["text"])
    assert " ".join(committed).split() == ["раз", "два"]


def test_session_flushes_on_silence():
    dec = FakeDecoder({0.0: "раз два три"})
    s = d.DictationSession(dec, decode_every_sec=0.4,
                           vad=d.SilenceDetector(hold_sec=0.4))
    s.feed(_speech(0.4))
    events = s.feed(_silence(0.5))
    assert [e["text"] for e in events if e["t"] == "commit"] == ["раз два три"]
    assert s._window.size == 0  # окно начато заново


def test_session_flushes_before_window_overflows():
    """18 секунд без паузы: окно нельзя растить бесконечно — gigaam режет на 20."""
    dec = FakeDecoder({0.0: "длинная речь"})
    s = d.DictationSession(dec, decode_every_sec=0.4, max_window_sec=1.0,
                           vad=d.SilenceDetector(hold_sec=99))
    s.feed(_speech(0.5))
    events = s.feed(_speech(0.6))
    assert any(e["t"] == "commit" for e in events)
    assert s._window.size == 0


def test_session_flush_is_idempotent_on_empty_window():
    s = d.DictationSession(FakeDecoder({0.0: "нечего"}))
    assert s.flush() == []


# --- протокол ------------------------------------------------------------------

def _pcm(samples: np.ndarray) -> str:
    return base64.b64encode((samples * 32767).astype("<i2").tobytes()).decode()


def test_pcm16_roundtrip():
    src = np.array([0.0, 0.5, -0.5], dtype=np.float32)
    back = d.pcm16_to_float32((src * 32767).astype("<i2").tobytes())
    assert np.allclose(back, src, atol=1e-3)


def _serve(lines, decode):
    out = io.StringIO()
    d.serve(stdin=io.StringIO("".join(l + "\n" for l in lines)), stdout=out, decode=decode)
    return [json.loads(l) for l in out.getvalue().splitlines()]


def test_serve_announces_ready_and_handles_audio():
    events = _serve(
        [json.dumps({"t": "audio", "pcm": _pcm(_speech(0.5))}),
         json.dumps({"t": "flush"}),
         json.dumps({"t": "quit"})],
        FakeDecoder({0.0: "привет мир"}),
    )
    assert events[0] == {"t": "ready"}
    assert [e["text"] for e in events if e["t"] == "commit"] == ["привет мир"]


def test_serve_survives_broken_line():
    events = _serve(["не json", json.dumps({"t": "quit"})], FakeDecoder({0.0: ""}))
    assert any(e["t"] == "error" for e in events)


def test_serve_reports_model_failure_and_exits():
    out = io.StringIO()

    def broken(_):
        raise RuntimeError("модель не загрузилась")

    code = d.serve(stdin=io.StringIO(""), stdout=out,
                   decode=None, model_type="нет такой")
    assert code == 1
    assert json.loads(out.getvalue().splitlines()[0])["t"] == "error"
