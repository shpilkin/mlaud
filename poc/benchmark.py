import sys, time
from gigaam_mlx import load_model
from gigaam_mlx.transcribe import transcribe_file

model_type = sys.argv[1]
files = sys.argv[2:]

t0 = time.time()
model, tok = load_model(model_type=model_type)
print(f"== model_type={model_type}  model load: {time.time()-t0:.1f}s ==", flush=True)

for i, f in enumerate(files):
    t = time.time()
    segs = transcribe_file(f, model=model, tokenizer=tok, model_type=model_type, verbose=False)
    dt = time.time() - t
    dur = segs[-1]['end'] if segs else 0.0
    text = " ".join(s['text'].strip() for s in segs)
    tag = "WARMUP" if i == 0 else "steady"
    rt = dur / dt if dt else 0
    print(f"[{i} {tag}] {f}: {dt:.1f}s for ~{dur:.0f}s audio  ({rt:.1f}x RT)  segs={len(segs)}", flush=True)
    print(f"    TEXT: {text[:400]}", flush=True)
