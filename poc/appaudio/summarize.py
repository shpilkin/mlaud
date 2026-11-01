"""Сводка прогона пробы S2: средний уровень по окнам сценария плюс события.

summarize.py <журнал пробы> <журнал драйвера>
Журнал драйвера: строки `WINDOW имя начало конец` (секунды от READY) и `NOTE …`.
"""
import math
import re
import sys

log_path, driver_path = sys.argv[1], sys.argv[2]
line_re = re.compile(r"^\[\s*([\d.]+)\] (.*)$")
levels_re = re.compile(r"(\w+) rms_dbfs=\[([^\]]*)\] peak_dbfs=\[([^\]]*)\] frames=(\d+) chunks=(\d+)")

ready_t = None
seconds = []  # (t, {label: (rms list, peak list, frames)})
events = []
for raw in open(log_path, encoding="utf-8"):
    m = line_re.match(raw.rstrip("\n"))
    if not m:
        continue
    t, text = float(m.group(1)), m.group(2)
    if text.startswith("READY"):
        ready_t = t
        events.append((t, text))
    elif text.startswith("t="):
        parts = {}
        for lm in levels_re.finditer(text):
            rms = [float(x) if x != "-inf" else -math.inf for x in lm.group(2).split(",") if x]
            peak = [float(x) if x != "-inf" else -math.inf for x in lm.group(3).split(",") if x]
            parts[lm.group(1)] = (rms, peak, int(lm.group(4)))
        seconds.append((t, parts))
    elif text.startswith(("EVENT", "ERROR", "DONE", "mode=", "default_output", "mic format", "probe ", "cpu_user")):
        events.append((t, text))

windows = []
for raw in open(driver_path, encoding="utf-8"):
    f = raw.split()
    if len(f) == 4 and f[0] == "WINDOW":
        windows.append((f[1], float(f[2]), float(f[3])))
    elif f and f[0] == "NOTE":
        events.append((None, raw.strip()))


def energy_mean(values):
    vals = [v for v in values if v > -math.inf]
    if not vals:
        return "-inf"
    return "%.1f" % (10 * math.log10(sum(10 ** (v / 10) for v in vals) / len(vals)))


def fmt(label, rows):
    chans = max((len(p[label][0]) for _, p in rows if label in p), default=0)
    cols = []
    for c in range(chans):
        cols.append(energy_mean([p[label][0][c] for _, p in rows if label in p and len(p[label][0]) > c]))
    frames = [p[label][2] for _, p in rows if label in p]
    return ", ".join(cols) if cols else "—", (min(frames), max(frames)) if frames else (0, 0)


if ready_t is None:
    print("READY не найден — захват не стартовал")
else:
    print(f"READY при t={ready_t:.2f}\n")
    print("| окно | секунды | app RMS dBFS по каналам | кадров/с | mic RMS dBFS |")
    print("|---|---|---|---|---|")
    for name, start, end in windows:
        lo, hi = ready_t + start, ready_t + end
        rows = [(t, p) for t, p in seconds if lo <= t <= hi]
        app, frames = fmt("app", rows)
        mic, _ = fmt("mic", rows)
        print(f"| {name} | {start:.0f}–{end:.0f} | {app} | {frames[0]}–{frames[1]} | {mic} |")
print("\nСобытия:")
for t, text in events:
    print(f"  [{t:7.2f}] {text}" if t is not None else f"  {text}")
if "-v" in sys.argv:
    print("\nПо секундам:")
    for t, p in seconds:
        print(f"  [{t:7.2f}] " + "  ".join(f"{k}={v[0]} frames={v[2]}" for k, v in p.items()))
