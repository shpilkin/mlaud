import sys, subprocess, tempfile, os, time, importlib
import soundfile as sf

T = importlib.import_module("gigaam_mlx.transcribe")
from gigaam_mlx import load_model

def afconvert_load(path, sr=16000):
    # afconvert decode to PCM wav (mono). Do NOT trust -r: read actual sr, resample in Python.
    tmp = tempfile.mktemp(suffix=".wav")
    subprocess.run(["afconvert", path, "-d", "LEI16", "-f", "WAVE", "-c", "1", tmp],
                   check=True, capture_output=True)
    audio, src_sr = sf.read(tmp, dtype="float32")
    os.remove(tmp)
    if src_sr != sr:
        import soxr
        audio = soxr.resample(audio, src_sr, sr)
    print(f"  [decoded src_sr={src_sr} -> {sr}, {len(audio)/sr:.1f}s]", flush=True)
    return audio

T.load_audio = afconvert_load

path = sys.argv[1]
model_type = sys.argv[2] if len(sys.argv) > 2 else "rnnt"

t0 = time.time()
model, tok = load_model(model_type=model_type)
t_load = time.time() - t0

t1 = time.time()
segs = T.transcribe_file(path, model=model, tokenizer=tok, model_type=model_type, verbose=False)
t_tr = time.time() - t1

dur = segs[-1]['end'] if segs else 0.0
print(f"== {model_type} | load {t_load:.1f}s | transcribe {t_tr:.1f}s | audio ~{dur:.0f}s | {dur/t_tr:.0f}x RT | {len(segs)} segments ==\n")

def srt_t(s):
    h=int(s//3600); m=int((s%3600)//60); sec=int(s%60); ms=int((s-int(s))*1000)
    return f"{h:02d}:{m:02d}:{sec:02d},{ms:03d}"

lines, srt = [], []
for i, s in enumerate(segs, 1):
    stamp = f"[{srt_t(s['start'])} -> {srt_t(s['end'])}]"
    print(stamp, s['text'].strip())
    lines.append(s['text'].strip())
    srt.append(f"{i}\n{srt_t(s['start'])} --> {srt_t(s['end'])}\n{s['text'].strip()}\n")

base = os.path.splitext(os.path.basename(path))[0]
open(f"{base}.txt", "w").write("\n".join(lines))
open(f"{base}.srt", "w").write("\n".join(srt))
print(f"\nSaved: {base}.txt , {base}.srt")
