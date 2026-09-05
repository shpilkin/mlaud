#!/bin/zsh
# Дымовая проверка раздела «Голоса»: реальный worker на копии сайдкаров во временном каталоге
# (`assign --none` меняет файлы, поэтому не на ~/ASR/service/speakers). См. README.md.
set -euo pipefail
cd "$(dirname "$0")"
root=$(mktemp -d "${TMPDIR:-/tmp}/mlaud-smoke-voices.XXXXXX")
trap 'rm -rf "$root"' EXIT

# Две записи с одинаковыми метками кластеров (как в жизни: SPEAKER_00, SPEAKER_01 в каждой):
# у новой один кластер к разметке, у старой — уже подписан. Схема — worker/tests/test_voices.py.
python3 - "$root" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
speakers = root / "service" / "speakers" / "2026-09"


def recording(base, processed_at, assigned):
    d = speakers / base
    d.mkdir(parents=True)
    txt, srt = root / f"{base}.txt", root / f"{base}.srt"
    first = assigned or "Спикер 1"
    txt.write_text(f"[00:00:00] {first}: привет\n[00:00:41] Спикер 2: угу\n", "utf-8")
    srt.write_text(f"1\n00:00:00,000 --> 00:00:01,000\n{first}: привет\n", "utf-8")
    emb0, emb1 = [0.0] * 8, [0.0] * 8
    emb0[0] = emb1[1] = 2.5
    sidecar = {
        "version": 1, "source": f"{base}.m4a", "base": base, "period": "2026-09",
        "processed_at": processed_at, "txt": str(txt), "srt": str(srt),
        "duration_sec": 60.0, "threshold": 0.75, "min_speech": 30.0,
        "clusters": [
            {"label": "SPEAKER_01", "display": "Спикер 1", "speech_sec": 54.0, "first_at": 0.0,
             "n_turns": 2, "quote": "привет", "clips": [], "embedding": emb0, "match": None,
             "written": first, "assigned": assigned, "dismissed": False, "rejected": []},
            {"label": "SPEAKER_00", "display": "Спикер 2", "speech_sec": 5.0, "first_at": 40.5,
             "n_turns": 1, "quote": "угу", "clips": [], "embedding": emb1, "match": None,
             "written": "Спикер 2", "assigned": None, "dismissed": False, "rejected": []},
        ],
    }
    (d / "speakers.json").write_text(json.dumps(sidecar, ensure_ascii=False, indent=2), "utf-8")


recording("new", "2026-09-03T10:00:00+00:00", None)
recording("old", "2026-09-01T10:00:00+00:00", "Милана Г")
(root / "voices").mkdir()
PY

swift run MLaudApp --smoke-voices "$root/service/speakers" "${MLAUD_PY:-../poc/.venv/bin/python}" \
    "${MLAUD_WORKER_DIR:-../worker}" "$root/voices"
