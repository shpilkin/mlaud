import sys, subprocess, tempfile, os, importlib
import soundfile as sf
T = importlib.import_module("gigaam_mlx.transcribe")  # the submodule, not the re-exported fn
from gigaam_mlx import load_model

def afconvert_load(path, sr=16000):
    tmp = tempfile.mktemp(suffix=".wav")
    subprocess.run(["afconvert", path, "-d", "LEI16", "-f", "WAVE", "-c", "1",
                    "-r", str(sr), tmp], check=True, capture_output=True)
    audio, _ = sf.read(tmp, dtype="float32")
    os.remove(tmp)
    return audio

T.load_audio = afconvert_load  # bypass ffmpeg entirely
model, tok = load_model(model_type="rnnt")
segs = T.transcribe_file(sys.argv[1], model=model, tokenizer=tok, model_type="rnnt", verbose=False)
print("SEGS:", len(segs))
print("TEXT:", " ".join(s['text'].strip() for s in segs)[:300])
