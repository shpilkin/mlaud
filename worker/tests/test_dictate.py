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



def test_stat_reports_how_the_phrase_closed():
    """Пауза и упор в предел окна — разные события, и различать их важно."""
    dec = FakeDecoder({0.0: "раз два"})
    s = d.DictationSession(dec, decode_every_sec=0.4,
                           vad=d.SilenceDetector(hold_sec=0.4))
    s.feed(_speech(0.4))
    stats = [e for e in s.feed(_silence(0.5)) if e["t"] == "stat"]
    assert stats and stats[0]["reason"] == "silence"

    s2 = d.DictationSession(dec, decode_every_sec=0.4, max_window_sec=1.0,
                            vad=d.SilenceDetector(hold_sec=99))
    s2.feed(_speech(0.5))
    stats2 = [e for e in s2.feed(_speech(0.6)) if e["t"] == "stat"]
    assert stats2 and stats2[0]["reason"] == "overflow"
    assert stats2[0]["window_sec"] > 1.0    # окно доросло до предела
    assert stats2[0]["decodes"] >= 1        # и каждый разбор стоил как целое окно


def test_stat_counters_reset_between_phrases():
    dec = FakeDecoder({0.0: "раз"})
    s = d.DictationSession(dec, decode_every_sec=0.4,
                           vad=d.SilenceDetector(hold_sec=0.4))
    s.feed(_speech(0.4)); s.feed(_silence(0.5))
    s.feed(_speech(0.4))
    stats = [e for e in s.feed(_silence(0.5)) if e["t"] == "stat"]
    assert stats[0]["window_sec"] < 1.5  # окно новой фразы, а не накопленное


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


# --- каналы звонка (feature-prompter.md §5.1, бриф этапа 3 §2) ------------------

PHRASE_KEYS = ["t", "ch", "phrase", "t0", "t1", "text", "reason", "window_sec", "decodes"]


def _channel(dec, ch="them", hold=0.4, **kw):
    return d.DictationSession(dec, decode_every_sec=0.4, vad=d.SilenceDetector(hold_sec=hold),
                              ch=ch, label=ch, **kw)


def _frames(s, *chunks):
    """Скормить куски кадрами по 0.1 с, как приходят буферы захвата; вернуть все события."""
    events = []
    for chunk in chunks:
        for i in range(0, chunk.size, 1600):
            events.extend(s.feed(chunk[i:i + 1600]))
    return events


def test_channel_events_carry_ch_and_phrase():
    dec = FakeDecoder({0.4: "раз", 0.8: "раз два", 1.2: "раз два три"})
    s = _channel(dec)
    events = [ev for _ in range(3) for ev in s.feed(_speech(0.4))]
    assert events and all(ev["ch"] == "them" and ev["phrase"] == 1 for ev in events)
    assert {ev["t"] for ev in events} <= {"commit", "preview"}
    assert [list(ev.keys()) for ev in events if ev["t"] == "commit"] == [["t", "ch", "phrase", "text"]]

    closed = s.feed(_silence(0.5))
    assert [ev["t"] for ev in closed if ev["t"] == "stat"] == []
    phrase = [ev for ev in closed if ev["t"] == "phrase"]
    assert len(phrase) == 1
    assert list(phrase[0].keys()) == PHRASE_KEYS
    assert phrase[0]["ch"] == "them" and phrase[0]["phrase"] == 1
    assert phrase[0]["reason"] == "silence"
    assert s.phrase == 2


def test_phrase_t0_t1_count_received_audio_since_open():
    s = _channel(FakeDecoder({0.0: "раз"}))
    phrases = []
    for chunk in (_speech(0.4), _silence(0.5), _speech(0.4), _silence(0.5)):
        for i in range(0, chunk.size, 1600):
            for ev in s.feed(chunk[i:i + 1600]):
                if ev["t"] == "phrase":
                    phrases.append((ev, s.received))
    assert len(phrases) == 2
    (p1, received1), (p2, received2) = phrases
    assert p1["t0"] == 0.0
    assert p1["t1"] == round(received1 / 16000, 2)
    assert abs((p1["t1"] - p1["t0"]) - p1["window_sec"]) < 0.11
    assert p2["t0"] == p1["t1"]
    assert p2["t1"] == round(received2 / 16000, 2)
    assert p2["phrase"] == 2 and p1["phrase"] == 1
    assert p2["t1"] > p1["t1"]


def test_reset_keeps_received_and_phrase():
    s = _channel(FakeDecoder({0.0: "раз"}))
    _frames(s, _speech(0.4), _silence(0.5))
    assert s.phrase == 2 and s.received == 16000 * 0.9
    s.feed(_speech(0.3))
    s.reset()
    assert s.phrase == 2 and s.received == int(16000 * 1.2)
    assert s._window.size == 0
    # следующая фраза отсчитывает t0 от open, а не от reset
    phrase = [ev for ev in _frames(s, _speech(0.4), _silence(0.5)) if ev["t"] == "phrase"][0]
    assert phrase["t0"] == 1.2 and phrase["phrase"] == 2


def test_phrase_text_is_full_window_not_tail():
    dec = FakeDecoder({0.4: "раз", 0.8: "раз два", 1.2: "раз два три"})
    s = _channel(dec, hold=99)
    commits = [ev["text"] for _ in range(3) for ev in s.feed(_speech(0.4)) if ev["t"] == "commit"]
    assert commits == ["раз"]
    events = s.flush(reason="flush")
    assert [ev["text"] for ev in events if ev["t"] == "commit"] == ["два три"]
    phrase = [ev for ev in events if ev["t"] == "phrase"][0]
    assert phrase["text"] == "раз два три"
    assert phrase["reason"] == "flush"


def _registry(decoders):
    return d.ChannelRegistry(lambda ch, label: d.DictationSession(
        decoders[ch], decode_every_sec=0.4, vad=d.SilenceDetector(hold_sec=0.4), ch=ch, label=label))


def test_registry_two_channels_independent():
    decoders = {"me": FakeDecoder({0.0: "я говорю"}), "them": FakeDecoder({0.0: "он отвечает"}),
                None: FakeDecoder({0.0: "диктовка"})}
    reg = _registry(decoders)
    assert reg.handle({"t": "open", "ch": "me", "label": "Я"}) == []
    assert reg.handle({"t": "open", "ch": "them", "label": "Собеседник"}) == []
    events = []
    # me: речь 0.4 + тишина 0.5; them: тишина 0.3, речь 0.4, тишина 0.5 — вперемешку
    me = np.concatenate([_speech(0.4), _silence(0.5)])
    them = np.concatenate([_silence(0.3), _speech(0.4), _silence(0.5)])
    for i in range(0, them.size, 1600):
        for ch, audio in (("me", me), ("them", them)):
            if i < audio.size:
                events.extend(reg.handle({"t": "audio", "ch": ch, "pcm": _pcm(audio[i:i + 1600])}))
    by_ch = {ch: [ev for ev in events if ev["ch"] == ch] for ch in ("me", "them")}
    assert all("ch" in ev for ev in events)
    assert " ".join(ev["text"] for ev in by_ch["me"] if ev["t"] == "commit") == "я говорю"
    assert " ".join(ev["text"] for ev in by_ch["them"] if ev["t"] == "commit") == "он отвечает"
    p_me = [ev for ev in by_ch["me"] if ev["t"] == "phrase"]
    p_them = [ev for ev in by_ch["them"] if ev["t"] == "phrase"]
    assert len(p_me) == 1 and len(p_them) == 1
    assert p_me[0]["phrase"] == 1 and p_them[0]["phrase"] == 1
    assert p_me[0]["t0"] == 0.0 and p_me[0]["t1"] == 0.8
    assert p_them[0]["t0"] == 0.0 and p_them[0]["t1"] == 1.1     # своя шкала: тишина в начале тоже принята
    assert decoders[None].calls == 0


def test_registry_without_ch_is_legacy():
    reg = _registry({None: FakeDecoder({0.0: "привет мир"})})
    events = reg.handle({"t": "audio", "pcm": _pcm(_speech(0.5))})
    events += reg.handle({"t": "flush"})
    assert events and all("ch" not in ev and "phrase" not in ev for ev in events)
    assert [ev["text"] for ev in events if ev["t"] == "commit"] == ["привет мир"]
    stats = [ev for ev in events if ev["t"] == "stat"]
    assert stats == [{"t": "stat", "reason": "manual", "window_sec": 0.5, "decodes": 1}]
    assert not any(ev["t"] == "phrase" for ev in events)


def test_registry_open_main_rejected():
    reg = _registry({})
    assert reg.handle({"t": "open", "ch": "main", "label": "x"}) == \
        [{"t": "error", "ch": "main", "message": "канал main зарезервирован"}]
    assert reg.handle({"t": "audio", "ch": "main", "pcm": _pcm(_speech(0.1))}) == \
        [{"t": "error", "ch": "main", "message": "канал main зарезервирован"}]
    assert reg._sessions == {}


def test_registry_open_without_ch_is_error():
    reg = _registry({})
    assert reg.handle({"t": "open", "label": "x"}) == [{"t": "error", "message": "open без ch"}]
    assert reg._sessions == {}


def test_close_flushes_with_reason_flush_then_drops():
    dec = FakeDecoder({0.0: "раз два"})
    reg = _registry({"them": dec})
    reg.handle({"t": "audio", "ch": "them", "pcm": _pcm(_speech(0.5))})   # без open — канал создан сам
    events = reg.handle({"t": "close", "ch": "them"})
    phrase = [ev for ev in events if ev["t"] == "phrase"]
    assert phrase and phrase[0]["reason"] == "flush" and phrase[0]["phrase"] == 1
    assert phrase[0]["t0"] == 0.0 and phrase[0]["t1"] == 0.5
    assert "them" not in reg._sessions
    assert reg.handle({"t": "close", "ch": "them"}) == []        # неизвестный ch — ничего
    reg.handle({"t": "audio", "ch": "them", "pcm": _pcm(_speech(0.5))})
    again = [ev for ev in reg.handle({"t": "close", "ch": "them"}) if ev["t"] == "phrase"]
    assert again[0]["phrase"] == 1 and again[0]["t0"] == 0.0


def test_reopen_starts_counters_from_zero():
    reg = _registry({"them": FakeDecoder({0.0: "раз"})})
    reg.handle({"t": "open", "ch": "them", "label": "a"})
    reg.handle({"t": "audio", "ch": "them", "pcm": _pcm(_speech(0.5))})
    reg.handle({"t": "flush", "ch": "them"})
    assert reg.session("them").phrase == 2
    assert reg.handle({"t": "open", "ch": "them", "label": "b"}) == []
    assert reg.session("them").phrase == 1 and reg.session("them").received == 0
    assert reg.session("them").label == "b"


def test_serve_channel_protocol_end_to_end():
    events = _serve(
        [json.dumps({"t": "open", "ch": "me", "label": "Я"}),
         json.dumps({"t": "open", "ch": "them", "label": "Собеседник"}),
         json.dumps({"t": "audio", "ch": "me", "pcm": _pcm(_speech(0.5))}),
         json.dumps({"t": "audio", "ch": "them", "pcm": _pcm(_speech(0.5))}),
         json.dumps({"t": "flush", "ch": "me"}),
         json.dumps({"t": "close", "ch": "me"}),
         json.dumps({"t": "close", "ch": "them"}),
         json.dumps({"t": "quit"})],
        FakeDecoder({0.0: "привет мир"}),
    )
    assert events[0] == {"t": "ready"}
    assert all("ch" in ev for ev in events[1:])
    assert not any(ev["t"] == "stat" for ev in events)
    phrases = [(ev["ch"], ev["reason"], ev["text"]) for ev in events if ev["t"] == "phrase"]
    assert phrases == [("me", "flush", "привет мир"), ("them", "flush", "привет мир")]
    assert [ev for ev in events if ev["t"] == "error"] == []


def test_quit_does_not_flush_channels():
    events = _serve(
        [json.dumps({"t": "open", "ch": "them", "label": "x"}),
         json.dumps({"t": "audio", "ch": "them", "pcm": _pcm(_speech(0.5))}),
         json.dumps({"t": "quit"})],
        FakeDecoder({0.0: "хвост"}),
    )
    assert not any(ev["t"] == "phrase" for ev in events)


def test_error_carries_ch_only_if_command_had_ch():
    reg = _registry({})
    assert reg.handle({"t": "wat", "ch": "them"}) == \
        [{"t": "error", "ch": "them", "message": "неизвестная команда: wat"}]
    assert reg.handle({"t": "wat"}) == [{"t": "error", "message": "неизвестная команда: wat"}]
    # исключение внутри serve (base64 без padding) — тот же принцип
    events = _serve(
        [json.dumps({"t": "audio", "ch": "them", "pcm": "AAA"}),
         json.dumps({"t": "audio", "pcm": "AAA"}),
         json.dumps({"t": "quit"})],
        FakeDecoder({0.0: ""}),
    )
    errors = [ev for ev in events if ev["t"] == "error"]
    assert len(errors) == 2
    assert errors[0]["ch"] == "them" and list(errors[0].keys()) == ["t", "ch", "message"]
    assert "ch" not in errors[1]


class _Clock:
    """Первый вызов — 0, дальше — «часы ушли» на заданное время."""

    def __init__(self, later):
        self.later = later
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return 0.0 if self.calls == 1 else self.later


def test_lag_watchdog_skips_interim_decodes_when_behind():
    dec = FakeDecoder({0.0: "раз два"})
    s = _channel(dec, hold=99, clock=_Clock(3.0), max_lag_sec=1.0)
    events = _frames(s, _speech(0.4))       # 0.4 с звука, часы ушли на 3 с — отставание 2.6 с
    assert dec.calls == 0 and events == []
    assert s._undecoded == int(16000 * 0.4)  # копится, не выбрасывается
    events = s.flush(reason="flush")         # закрытие фразы разбирает всегда
    assert dec.calls == 1
    assert [ev["t"] for ev in events] == ["commit", "preview", "phrase"]

    dec2 = FakeDecoder({0.0: "раз два"})
    s2 = _channel(dec2, hold=99, clock=_Clock(3.0), max_lag_sec=None)
    _frames(s2, _speech(0.4))
    assert dec2.calls == 1

    dec3 = FakeDecoder({0.0: "раз два"})
    s3 = _channel(dec3, hold=99, clock=_Clock(0.5), max_lag_sec=1.0)   # отставание 0.1 с — в норме
    _frames(s3, _speech(0.4))
    assert dec3.calls == 1


def test_make_session_lag_only_for_channels():
    dec = FakeDecoder({0.0: ""})
    legacy = d._make_session(dec, None, None)
    assert legacy.max_lag_sec is None and legacy.ch is None
    them = d._make_session(dec, "them", "x")
    assert them.max_lag_sec == 1.0 and them.ch == "them" and them.label == "x"
