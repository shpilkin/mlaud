"""S1 — два канала через один резидентный распознаватель: держит ли реальное время.

Что проверяем (docs/task-app-ui-and-prompter.md §3, OQ-12): две `DictationSession` над
ОДНИМ загруженным `decode` в ОДНОМ потоке, как в `dictate.serve()`, при звуке с двух
дорожек в темпе реального времени. Метрики — отставание потребителя от продюсера по
wall-clock, задержка события фразы, стоимость разбора по длине окна.

Путь данных повторяет боевой: продюсер шлёт JSON-строки с base64 int16 (как Swift через
stdin), потребитель разбирает JSON, декодирует base64, кормит сессию канала. Единственное,
что здесь прототипируется, — реестр `{ch: DictationSession}` (`ChannelRegistry`): в таком
виде он и должен уехать в `dictate.py`.

Запуск (из корня репозитория):
    PYTHONPATH=worker worker/.venv/bin/python poc/live2ch/run.py select
    PYTHONPATH=worker worker/.venv/bin/python poc/live2ch/run.py run --name base --cadence fixed --window 18
    PYTHONPATH=worker worker/.venv/bin/python poc/live2ch/run.py report
    PYTHONPATH=worker worker/.venv/bin/python poc/live2ch/run.py run --name pipe --pipe
Сырые данные — ~/ASR/spikes/live2ch/ (вне репозитория; переопределение LIVE2CH_OUT).

Режим `--pipe` закрывает «пайп не измерен» (RESULT.md): те же строки уходят в
`python -m mlaud_worker.dictate` через stdin, события читаются из stdout. Окно и каденс —
как в бою (константы dictate.py), `--window`/`--cadence` не действуют; занятость декодера
через пайп не видна, меряются задержки событий `phrase` по кадру, который их закрыл.
"""

import argparse
import base64
import json
import os
import queue
import shlex
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

from mlaud_worker import dictate

SR = dictate.SR
CHUNK_SEC = 0.1                      # как приходят буферы захвата (~0.1 с)
CHUNK = int(CHUNK_SEC * SR)
OUT = Path(os.environ.get("LIVE2CH_OUT") or Path.home() / "ASR/spikes/live2ch")
ARCHIVE = Path.home() / "ASR/Processed/AllRecords"

# Две разные записи: разные люди, разная манера. «Я» и «собеседник» здесь условны —
# нагрузка одинакова, важно лишь, что дорожки независимы.
SOURCES = {
    "me": ARCHIVE / "2026-08" / "17.08 встреча.m4a",
    "them": ARCHIVE / "2026-09" / "2026-09-03_16-18-10_Запись 14.m4a",
}


# --------------------------------------------------------------------------- реестр каналов

class ChannelRegistry:
    """Сессии по каналам над одним decode. Прототип того, что уедет в dictate.serve().

    Команда без поля `ch` относится к каналу `main` — так диктовка продолжает работать
    без изменений. `make_session(ch)` создаёт сессию с СВОИМИ трекером и VAD.
    """

    def __init__(self, make_session):
        self._make = make_session
        self._sessions: dict[str, dictate.DictationSession] = {}

    def session(self, ch: str) -> dictate.DictationSession:
        s = self._sessions.get(ch)
        if s is None:
            s = self._make(ch)
            self._sessions[ch] = s
        return s

    def handle(self, msg: dict) -> list[dict]:
        """Одна команда → события (каждое с полем ch)."""
        kind = msg.get("t")
        ch = msg.get("ch", "main")
        if kind == "open":
            self.session(ch)
            return []
        if kind == "audio":
            samples = dictate.pcm16_to_float32(base64.b64decode(msg.get("pcm", "")))
            events = self.session(ch).feed(samples)
        elif kind == "flush":
            events = self.session(ch).flush()
        elif kind == "reset":
            self.session(ch).reset()
            events = []
        elif kind == "close":
            events = self.session(ch).flush() if ch in self._sessions else []
            self._sessions.pop(ch, None)
        else:
            events = [{"t": "error", "message": f"неизвестная команда: {kind}"}]
        for ev in events:
            ev["ch"] = ch
        return events


class AdaptiveSession(dictate.DictationSession):
    """Каденс переразбора зависит от длины окна: 0.4 с до 5 с окна, дальше пропорционально.

    Цена — хвост обновляется реже на длинных монологах; устоявшийся текст не страдает.
    """

    def __init__(self, decode, base_sec: float = 0.4, knee_sec: float = 5.0, **kw):
        super().__init__(decode, decode_every_sec=base_sec, **kw)
        self.base_sec = base_sec
        self.knee_sec = knee_sec

    def feed(self, samples):
        window_sec = self._window.size / self.sr
        every = self.base_sec * max(1.0, window_sec / self.knee_sec)
        self.decode_every = int(every * self.sr)
        return super().feed(samples)


# --------------------------------------------------------------------------- выбор отрезков

def speech_fraction(audio: np.ndarray, frame: int = CHUNK) -> np.ndarray:
    n = audio.size // frame
    frames = audio[: n * frame].reshape(n, frame)
    rms = np.sqrt(np.mean(np.square(frames, dtype=np.float64), axis=1))
    return (rms >= dictate.SILENCE_RMS).astype(np.float64)


def select_segments(minutes: float) -> dict:
    from mlaud_worker.audio import load_audio

    OUT.mkdir(parents=True, exist_ok=True)
    win = int(minutes * 60 / CHUNK_SEC)
    info = {}
    for ch, path in SOURCES.items():
        audio = load_audio(str(path))
        speech = speech_fraction(audio)
        # Плотнейшее по речи окно; скользящая сумма без numpy-магии.
        cs = np.concatenate([[0.0], np.cumsum(speech)])
        best, best_i = -1.0, 0
        for i in range(0, max(1, speech.size - win)):
            s = cs[i + win] - cs[i]
            if s > best:
                best, best_i = s, i
        start = best_i * CHUNK
        seg = audio[start: start + win * CHUNK]
        np.save(OUT / f"seg_{ch}.npy", seg)
        info[ch] = {
            "file": str(path),
            "start_sec": round(start / SR, 1),
            "seconds": round(seg.size / SR, 1),
            "speech_fraction": round(best / win, 3),
        }
        print(f"{ch}: {path.name} от {info[ch]['start_sec']} с, речь {info[ch]['speech_fraction']:.0%}")
    (OUT / "segments.json").write_text(json.dumps(info, ensure_ascii=False, indent=2))
    return info


# --------------------------------------------------------------------------- прогон

class Producer(threading.Thread):
    """Шлёт кадры обоих каналов в темпе реального времени, независимо от потребителя.

    Дедлайн считается от старта, а не sleep(0.1) в цикле — иначе дрейф. Строки JSON и
    base64 готовятся заранее: продюсер должен быть дешевле захвата, а не дороже.
    """

    def __init__(self, q: queue.Queue, segments: dict[str, np.ndarray], channels: list[str]):
        super().__init__(daemon=True)
        self.q = q
        self.channels = channels
        self.lines = {}
        self.speech = {}
        for ch in channels:
            seg = segments[ch]
            n = seg.size // CHUNK
            pcm = np.clip(seg[: n * CHUNK] * 32767.0, -32768, 32767).astype("<i2").reshape(n, CHUNK)
            self.lines[ch] = [
                json.dumps({"t": "audio", "ch": ch, "pcm": base64.b64encode(row.tobytes()).decode()})
                for row in pcm
            ]
            self.speech[ch] = speech_fraction(seg[: n * CHUNK]).astype(bool)
        self.n = min(len(self.lines[ch]) for ch in channels)
        self.started_at = None

    def run(self):
        self.started_at = time.perf_counter()
        for i in range(self.n):
            deadline = self.started_at + (i + 1) * CHUNK_SEC   # кадр i «пришёл» к концу своего окна
            now = time.perf_counter()
            if deadline > now:
                time.sleep(deadline - now)
            produced = time.perf_counter()
            for ch in self.channels:
                self.q.put((self.lines[ch][i], produced, ch, bool(self.speech[ch][i]), i))
        for ch in self.channels:
            self.q.put((json.dumps({"t": "flush", "ch": ch}), time.perf_counter(), ch, False, None))
        self.q.put((json.dumps({"t": "quit"}), time.perf_counter(), None, False, None))


def run(name: str, cadence: str, window: float, channels: list[str], minutes: float,
        model_type: str) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    segments = {ch: np.load(OUT / f"seg_{ch}.npy") for ch in channels}
    limit = int(minutes * 60 * SR)
    segments = {ch: seg[:limit] for ch, seg in segments.items()}

    t0 = time.perf_counter()
    decode = dictate._build_decoder(model_type)
    load_sec = time.perf_counter() - t0
    # Прогрев: первый разбор в MLX компилирует графы, это не нагрузка живого режима.
    decode(np.zeros(SR, dtype=np.float32))

    decodes: list[dict] = []          # {window_sec, sec, ch}
    current = {"ch": None, "produced": 0.0}

    def timed_decode(audio):
        t = time.perf_counter()
        text = decode(audio)
        decodes.append({"ch": current["ch"], "window_sec": round(audio.size / SR, 2),
                        "sec": round(time.perf_counter() - t, 4)})
        return text

    def make_session(ch):
        if cadence == "adaptive":
            return AdaptiveSession(timed_decode, max_window_sec=window)
        return dictate.DictationSession(timed_decode, max_window_sec=window)

    registry = ChannelRegistry(make_session)
    q: queue.Queue = queue.Queue()
    producer = Producer(q, segments, channels)

    lags: list[dict] = []             # по каждому кадру: когда потреблён, отставание
    events: list[dict] = []
    last_speech_at = {ch: None for ch in channels}
    raw = open(OUT / f"{name}.events.jsonl", "w")

    producer.start()
    started = producer.started_at or time.perf_counter()
    while True:
        line, produced, ch, has_speech, _ = q.get()
        now = time.perf_counter()
        msg = json.loads(line)
        if msg.get("t") == "quit":
            break
        if msg.get("t") == "audio":
            lags.append({"t": round(now - started, 3), "ch": ch, "lag": round(now - produced, 4)})
            if has_speech:
                last_speech_at[ch] = produced
        current["ch"], current["produced"] = ch, produced
        for ev in registry.handle(msg):
            done = time.perf_counter()
            ev["at"] = round(done - started, 3)
            if ev["t"] == "stat":
                ev["processing_latency"] = round(done - produced, 3)
                if ev["reason"] == "silence" and last_speech_at[ch] is not None:
                    ev["perceived_latency"] = round(done - last_speech_at[ch], 3)
            events.append(ev)
            raw.write(json.dumps(ev, ensure_ascii=False) + "\n")
    raw.close()
    wall = time.perf_counter() - started

    summary = summarize(name, cadence, window, channels, minutes, load_sec, wall, lags, decodes, events)
    (OUT / f"{name}.summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    (OUT / f"{name}.lags.json").write_text(json.dumps(lags))
    (OUT / f"{name}.decodes.json").write_text(json.dumps(decodes))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return summary


def run_pipe(name: str, channels: list[str], minutes: float, model_type: str,
             worker_cmd: list[str] | None = None) -> dict:
    """Тот же продюсер, но потребитель — настоящий `python -m mlaud_worker.dictate` за пайпом.

    Отставание по кадрам изнутри процесса не видно, поэтому меряем задержку события
    `phrase` от кадра, который его закрыл: индекс кадра восстанавливается из `t1`
    (кадры ровно по 0.1 с принятого звука — так `dictate.py` и считает `t1`).
    """
    OUT.mkdir(parents=True, exist_ok=True)
    segments = {ch: np.load(OUT / f"seg_{ch}.npy") for ch in channels}
    limit = int(minutes * 60 * SR)
    segments = {ch: seg[:limit] for ch, seg in segments.items()}

    cmd = worker_cmd or [sys.executable, "-m", "mlaud_worker.dictate"]
    t0 = time.perf_counter()
    child = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                             encoding="utf-8", bufsize=1,
                             env={**os.environ, "MLAUD_MODEL": model_type})
    first = json.loads(child.stdout.readline())
    if first.get("t") != "ready":
        child.kill()
        raise RuntimeError(f"распознаватель не поднялся: {first}")
    load_sec = time.perf_counter() - t0

    incoming: list[tuple[dict, float]] = []

    def reader():
        for line in child.stdout:
            incoming.append((json.loads(line), time.perf_counter()))

    reader_thread = threading.Thread(target=reader, daemon=True)
    reader_thread.start()

    def send(line: str) -> None:
        child.stdin.write(line + "\n")
        child.stdin.flush()

    for ch in channels:
        send(json.dumps({"t": "open", "ch": ch, "label": ch}))

    q: queue.Queue = queue.Queue()
    producer = Producer(q, segments, channels)
    produced_at: dict[str, dict[int, float]] = {ch: {} for ch in channels}

    producer.start()
    started = producer.started_at or time.perf_counter()
    while True:
        line, produced, ch, has_speech, i = q.get()
        msg = json.loads(line)
        if msg.get("t") == "quit":
            break
        if i is not None:
            produced_at[ch][i] = produced
        send(line)
    for ch in channels:
        send(json.dumps({"t": "close", "ch": ch}))
    send(json.dumps({"t": "quit"}))
    child.stdin.close()
    child.wait(timeout=120)
    reader_thread.join(timeout=10)
    wall = time.perf_counter() - started

    events: list[dict] = []
    with open(OUT / f"{name}.events.jsonl", "w") as raw:
        for ev, at in incoming:
            ev["at"] = round(at - started, 3)
            if ev["t"] == "phrase" and ev.get("ch") in produced_at:
                idx = int(round(ev["t1"] / CHUNK_SEC)) - 1
                closing = produced_at[ev["ch"]].get(idx)
                if closing is not None:
                    ev["processing_latency"] = round(at - closing, 3)
                speech = producer.speech[ev["ch"]]
                spoken = [j for j in range(min(idx, speech.size - 1), -1, -1) if speech[j]]
                if ev["reason"] == "silence" and spoken and spoken[0] in produced_at[ev["ch"]]:
                    ev["perceived_latency"] = round(at - produced_at[ev["ch"]][spoken[0]], 3)
            events.append(ev)
            raw.write(json.dumps(ev, ensure_ascii=False) + "\n")

    summary = summarize(name, "fixed", dictate.MAX_WINDOW_SEC, channels, minutes, load_sec,
                        wall, [], [], events)
    summary["pipe"] = True
    summary["worker_exit_code"] = child.returncode
    (OUT / f"{name}.summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return summary


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    k = min(len(s) - 1, max(0, int(round(p / 100 * (len(s) - 1)))))
    return round(s[k], 3)


def summarize(name, cadence, window, channels, minutes, load_sec, wall, lags, decodes, events):
    lag_values = [x["lag"] for x in lags]
    over1 = sum(1 for v in lag_values if v > 1.0)
    tail = lag_values[-len(channels) * 50:] if lag_values else []   # последние 5 с
    per_ch = {}
    for ch in channels:
        stats = [e for e in events if e["t"] in ("stat", "phrase") and e["ch"] == ch]
        sil = [e for e in stats if e["reason"] == "silence"]
        per_ch[ch] = {
            "phrases": len(stats),
            "silence": len(sil),
            "overflow": sum(1 for e in stats if e["reason"] == "overflow"),
            "commits": sum(1 for e in events if e["t"] == "commit" and e["ch"] == ch),
            "processing_latency_p50": pct([e["processing_latency"] for e in stats], 50),
            "processing_latency_p95": pct([e["processing_latency"] for e in stats], 95),
            "processing_latency_max": pct([e["processing_latency"] for e in stats], 100),
            "perceived_latency_p50": pct([e["perceived_latency"] for e in sil if "perceived_latency" in e], 50),
            "perceived_latency_p95": pct([e["perceived_latency"] for e in sil if "perceived_latency" in e], 95),
            "perceived_latency_max": pct([e["perceived_latency"] for e in sil if "perceived_latency" in e], 100),
            "max_window_sec": max((d["window_sec"] for d in decodes if d["ch"] == ch), default=0),
        }
    buckets = {}
    for d in decodes:
        b = f"{int(d['window_sec'] // 5) * 5:02d}-{int(d['window_sec'] // 5) * 5 + 5:02d}s"
        buckets.setdefault(b, []).append(d["sec"])
    decode_by_window = {b: {"n": len(v), "mean": round(statistics.mean(v), 4), "max": round(max(v), 4)}
                        for b, v in sorted(buckets.items())}
    busy = sum(d["sec"] for d in decodes)
    return {
        "name": name, "cadence": cadence, "window_sec": window, "channels": channels,
        "minutes": minutes, "model_load_sec": round(load_sec, 2), "wall_sec": round(wall, 1),
        "decodes": len(decodes), "decode_busy_sec": round(busy, 1),
        "decode_busy_fraction": round(busy / wall, 3) if wall and decodes else None,
        "lag_p50": pct(lag_values, 50), "lag_p95": pct(lag_values, 95), "lag_max": pct(lag_values, 100),
        "lag_over_1s_fraction": round(over1 / len(lag_values), 4) if lag_values else None,
        "lag_final_mean": round(statistics.mean(tail), 3) if tail else None,
        "decode_by_window": decode_by_window,
        "per_channel": per_ch,
    }


def _pct_cell(v, digits=0) -> str:
    return "—" if v is None else f"{v:.{digits}%}"


def report() -> str:
    rows = []
    for p in sorted(OUT.glob("*.summary.json")):
        rows.append(json.loads(p.read_text()))
    lines = ["| прогон | каденс | окно | каналов | занятость декодера | отставание p50 / p95 / max, с | доля >1 с | отставание в конце, с | фразы (пауза/переполнение) | задержка обработки p50/p95/max, с | воспринимаемая p50/p95, с |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        ph = "; ".join(f"{ch}: {c['silence']}/{c['overflow']}" for ch, c in r["per_channel"].items())
        pl = "; ".join(f"{ch}: {c['processing_latency_p50']}/{c['processing_latency_p95']}/{c['processing_latency_max']}"
                       for ch, c in r["per_channel"].items())
        pv = "; ".join(f"{ch}: {c['perceived_latency_p50']}/{c['perceived_latency_p95']}"
                       for ch, c in r["per_channel"].items())
        lines.append(f"| {r['name']} | {r['cadence']} | {r['window_sec']} | {len(r['channels'])} | "
                     f"{_pct_cell(r['decode_busy_fraction'])} | {r['lag_p50']} / {r['lag_p95']} / {r['lag_max']} | "
                     f"{_pct_cell(r['lag_over_1s_fraction'], 1)} | {r['lag_final_mean']} | {ph} | {pl} | {pv} |")
    text = "\n".join(lines)
    print(text)
    return text


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select"); s.add_argument("--minutes", type=float, default=5)
    r = sub.add_parser("run")
    r.add_argument("--name", required=True)
    r.add_argument("--cadence", choices=["fixed", "adaptive"], default="fixed")
    r.add_argument("--window", type=float, default=dictate.MAX_WINDOW_SEC)
    r.add_argument("--channels", default="me,them")
    r.add_argument("--minutes", type=float, default=5)
    r.add_argument("--model", default=os.environ.get("MLAUD_MODEL") or "rnnt")
    r.add_argument("--pipe", action="store_true", help="через stdin/stdout python -m mlaud_worker.dictate")
    r.add_argument("--worker-cmd", default=None, help="команда распознавателя для --pipe (по умолчанию модуль dictate)")
    sub.add_parser("report")
    a = ap.parse_args()
    if a.cmd == "select":
        select_segments(a.minutes)
    elif a.cmd == "run" and a.pipe:
        run_pipe(a.name, a.channels.split(","), a.minutes, a.model,
                 shlex.split(a.worker_cmd) if a.worker_cmd else None)
    elif a.cmd == "run":
        run(a.name, a.cadence, a.window, a.channels.split(","), a.minutes, a.model)
    else:
        report()


if __name__ == "__main__":
    main()
