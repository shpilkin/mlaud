"""Тон для «другого приложения»: WAV 48 кГц, стерео, 16 бит, с плавными краями."""
import math
import struct
import sys
import wave

path, freq, seconds = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
rate, amp, fade = 48000, 0.5, 0.05
n = int(rate * seconds)
with wave.open(path, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(rate)
    frames = bytearray()
    for i in range(n):
        t = i / rate
        env = min(1.0, t / fade, (seconds - t) / fade)
        s = int(32767 * amp * env * math.sin(2 * math.pi * freq * t))
        frames += struct.pack("<hh", s, s)
    w.writeframes(bytes(frames))
