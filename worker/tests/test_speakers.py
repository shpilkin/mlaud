"""Сайдкар записи для разметки голосов: сборка, клипы, смысл полей, переподпись, ретенция."""

import json
import os
import time

import numpy as np
import pytest
import soundfile as sf

from mlaud_worker import speakers as spk
from mlaud_worker.audio import TARGET_SR
from mlaud_worker.config import Config
from mlaud_worker.spkid import Identity

DIM = 8


def unit(i, scale=2.5):
    v = np.zeros(DIM, dtype=np.float32)
    v[i] = scale
    return v


def make_cfg(tmp_path) -> Config:
    return Config(inbox=tmp_path / "in", output=tmp_path / "out", processed=tmp_path / "p",
                  failed=tmp_path / "f", service=tmp_path / "service",
                  voices_dir=tmp_path / "voices", identify=True)


TURNS = [
    {"start": 0.0, "end": 40.0, "speaker": "SPEAKER_00"},
    {"start": 40.5, "end": 45.5, "speaker": "SPEAKER_01"},   # 5 c — короткий
    {"start": 46.0, "end": 60.0, "speaker": "SPEAKER_00"},   # итого 54 c
]
CENTROIDS = {"SPEAKER_00": unit(0), "SPEAKER_01": unit(1)}
NAMES = {"SPEAKER_00": "Милана Г(?)", "SPEAKER_01": "Спикер 2"}
IDENTS = {"SPEAKER_00": Identity("Милана Г", 0.77, False)}
SEGMENTS = [
    {"start": 0.0, "end": 1.0, "text": "привет: всем", "speaker": "Милана Г(?)"},
    {"start": 2.0, "end": 30.0, "text": "самая  длинная реплика этого человека", "speaker": "Милана Г(?)"},
    {"start": 41.0, "end": 41.5, "text": "угу", "speaker": "Спикер 2"},
]


def test_build_clusters_fields():
    cs = spk.build_clusters(TURNS, CENTROIDS, NAMES, IDENTS, SEGMENTS, 30.0)
    assert [c["display"] for c in cs] == ["Спикер 1", "Спикер 2"]
    a, b = cs
    assert a["label"] == "SPEAKER_00" and a["speech_sec"] == 54.0 and a["n_turns"] == 2
    assert a["first_at"] == 0.0 and b["first_at"] == 40.5
    assert a["quote"] == "самая длинная реплика этого человека"
    assert len(a["embedding"]) == DIM and a["embedding"][0] == 2.5
    assert a["match"] == {"name": "Милана Г", "score": 0.77, "sure": False}
    assert a["written"] == "Милана Г(?)" and a["assigned"] is None and a["rejected"] == []
    assert b["match"] is None and b["written"] == "Спикер 2" and b["quote"] == "угу"
    assert b["embedding"] is not None


def test_build_clusters_zero_embedding_is_null():
    cs = spk.build_clusters(TURNS, {"SPEAKER_00": np.zeros(DIM)}, NAMES, {}, [], 30.0)
    assert cs[0]["embedding"] is None and cs[1]["embedding"] is None


def test_quote_is_truncated():
    long = "слово " * 60
    cs = spk.build_clusters(TURNS, CENTROIDS, NAMES, {},
                            [{"start": 0, "end": 1, "text": long, "speaker": "Милана Г(?)"}], 30.0)
    assert len(cs[0]["quote"]) <= spk.QUOTE_MAX and cs[0]["quote"].endswith("…")


def _cluster(**over):
    base = {"label": "SPEAKER_00", "display": "Спикер 1", "speech_sec": 60.0,
            "embedding": [1.0], "match": None, "written": "Спикер 1",
            "assigned": None, "dismissed": False, "rejected": []}
    base.update(over)
    return base


def test_current_name_and_needs_attention():
    sure = {"name": "я", "score": 0.83, "sure": True}
    unsure = {"name": "Дина П", "score": 0.77, "sure": False}
    cases = [
        (_cluster(), "Спикер 1", True),
        (_cluster(match=sure), "я", False),
        (_cluster(match=unsure), "Дина П(?)", True),
        (_cluster(match=unsure, assigned="Дина П"), "Дина П", False),
        (_cluster(match=unsure, rejected=["Дина П"]), "Спикер 1", True),
        (_cluster(match=sure, rejected=["я"]), "Спикер 1", True),
        (_cluster(dismissed=True), "Спикер 1", False),
        (_cluster(match=unsure, dismissed=True), "Спикер 1", False),
        (_cluster(assigned="Кира Л", dismissed=True), "Кира Л", False),
        (_cluster(match=unsure, mixed=True), "Спикер 1 (смесь голосов)", False),
        (_cluster(mixed=True, assigned="Кира Л"), "Кира Л", False),
        (_cluster(match=unsure, hidden=True), "Дина П(?)", False),
        (_cluster(mixed=True, dismissed=True), "Спикер 1 (смесь голосов)", False),
        (_cluster(speech_sec=12.0), "Спикер 1", False),
        (_cluster(embedding=None), "Спикер 1", False),
    ]
    for c, name, attention in cases:
        assert spk.current_name(c) == name, c
        assert spk.needs_attention(c, 30.0) is attention, c


def _synth_audio(path, seconds=60):
    rng = np.random.default_rng(0)
    sf.write(path, (rng.standard_normal(seconds * TARGET_SR) * 0.1).astype(np.float32), TARGET_SR)


def _outputs(tmp_path):
    txt, srt = tmp_path / "rec.txt", tmp_path / "rec.srt"
    txt.write_text("[00:00:00] Милана Г(?): привет: всем\n[00:00:41] Спикер 2: угу\n", "utf-8")
    srt.write_text("1\n00:00:00,000 --> 00:00:01,000\nМилана Г(?): привет: всем\n\n"
                   "2\n00:00:41,000 --> 00:00:41,500\nСпикер 2: угу\n", "utf-8")
    return {"txt": txt, "srt": srt}


def test_write_sidecar_with_clips(tmp_path):
    cfg = make_cfg(tmp_path)
    audio = tmp_path / "rec.wav"
    _synth_audio(audio)
    sidecar = spk.write(cfg, audio, period="2026-09", base="rec", outputs=_outputs(tmp_path),
                        turns=TURNS, centroids=CENTROIDS, names=NAMES, idents=IDENTS,
                        segments=SEGMENTS)
    d = spk.sidecar_dir(cfg, "2026-09", "rec")
    assert (d / spk.FILE_NAME).exists() and "clips_error" not in sidecar
    assert (spk.root(cfg).stat().st_mode & 0o777) == 0o700
    assert (d.stat().st_mode & 0o777) == 0o700
    assert sidecar["source"] == "rec.wav" and sidecar["duration_sec"] == 60.0
    assert sidecar["threshold"] == 0.75 and sidecar["min_speech"] == 30.0

    long, short = sidecar["clusters"]
    assert len(long["clips"]) == 2                      # два turn'а → два окна, не три
    assert len(long["clip_starts"]) == 2 and long["clip_starts"][0] < long["clip_starts"][1]
    assert long["mixed"] is False
    for rel in long["clips"]:
        info = sf.info(d / rel)
        assert info.samplerate == TARGET_SR and 0.5 <= info.duration <= spk.CLIP_SEC + 0.01
    assert len(short["clips"]) == 1                      # послушать можно и короткого
    assert spk.pending_count(sidecar) == 1                # неуверенный длинный — к разметке
    assert spk.load(d / spk.FILE_NAME) == sidecar


def test_write_sidecar_without_audio_keeps_sidecar(tmp_path):
    cfg = make_cfg(tmp_path)
    sidecar = spk.write(cfg, tmp_path / "missing.m4a", period="2026-09", base="rec",
                        outputs=_outputs(tmp_path), turns=TURNS, centroids=CENTROIDS,
                        names=NAMES, idents=IDENTS, segments=SEGMENTS)
    assert "clips_error" in sidecar
    assert (spk.sidecar_dir(cfg, "2026-09", "rec") / spk.FILE_NAME).exists()
    assert sidecar["clusters"][0]["clips"] == []


def test_relabel_rewrites_prefixes_and_written(tmp_path):
    cfg = make_cfg(tmp_path)
    outputs = _outputs(tmp_path)
    spk.write(cfg, tmp_path / "missing.m4a", period="2026-09", base="rec", outputs=outputs,
              turns=TURNS, centroids=CENTROIDS, names=NAMES, idents=IDENTS, segments=SEGMENTS)
    path = spk.sidecar_dir(cfg, "2026-09", "rec") / spk.FILE_NAME

    sidecar = spk.load(path)
    sidecar["clusters"][0]["assigned"] = "Милана Г"
    spk.save(path, sidecar)
    res = spk.relabel_transcript(path)
    assert res["changed"] == 2 and len(res["files"]) == 2
    # текст с «: » внутри не пострадал, заменён только префикс
    assert outputs["txt"].read_text("utf-8") == \
        "[00:00:00] Милана Г: привет: всем\n[00:00:41] Спикер 2: угу\n"
    assert "\nМилана Г: привет: всем\n" in outputs["srt"].read_text("utf-8")
    assert spk.load(path)["clusters"][0]["written"] == "Милана Г"

    # повторно — нечего менять
    assert spk.relabel_transcript(path)["changed"] == 0

    # «Нет» на автоузнавание после ручного имени снято: обратно в «Спикер 1»
    sidecar = spk.load(path)
    sidecar["clusters"][0]["assigned"] = None
    sidecar["clusters"][0]["rejected"] = ["Милана Г"]
    spk.save(path, sidecar)
    assert spk.relabel_transcript(path)["changed"] == 2
    assert outputs["txt"].read_text("utf-8").startswith("[00:00:00] Спикер 1: привет: всем")


def test_rewrite_lines_longest_name_first():
    lines = ["[00:00:00] Спикер 12: раз", "[00:00:01] Спикер 1: два", "не реплика"]
    out, changed = spk._rewrite_lines(lines, {"Спикер 1": "A", "Спикер 12": "B"}, txt=True)
    assert out == ["[00:00:00] B: раз", "[00:00:01] A: два", "не реплика"] and changed == 2
    srt = ["1", "00:00:00,000 --> 00:00:01,000", "Спикер 1: два", ""]
    out, changed = spk._rewrite_lines(srt, {"Спикер 1": "A"}, txt=False)
    assert out[2] == "A: два" and changed == 1


def test_sweep_tombstones_old_recordings(tmp_path):
    cfg = make_cfg(tmp_path)
    old = spk.sidecar_dir(cfg, "2026-07", "old")
    fresh = spk.sidecar_dir(cfg, "2026-09", "fresh")
    cluster = {"label": "SPEAKER_00", "display": "Спикер 1", "speech_sec": 40.0, "written": "Ося",
               "assigned": "Ося", "embedding": [1.0, 0.0], "clips": ["clips/SPEAKER_00_0.wav"]}
    for d in (old, fresh):
        d.mkdir(parents=True)
        (d / spk.FILE_NAME).write_text(json.dumps({"min_speech": 30.0, "clusters": [cluster]}), "utf-8")
        (d / "clips").mkdir()
    long_ago = time.time() - spk.DEFAULT_MAX_AGE - 60
    os.utime(old / spk.FILE_NAME, (long_ago, long_ago))

    removed = spk.sweep(cfg)
    assert removed == [old]
    # Надгробие: файл остался с именами, клипы и вектор стёрты, в списке живых его нет.
    stone = spk.load(old / spk.FILE_NAME)
    assert stone["removed"] == "swept" and stone["removed_at"]
    assert stone["clusters"][0]["assigned"] == "Ося"
    assert stone["clusters"][0]["embedding"] is None and stone["clusters"][0]["clips"] == []
    assert not (old / "clips").exists()
    assert spk.pending_count(stone) == 0
    assert fresh.exists() and (fresh / "clips").exists()
    assert spk.sweep(cfg) == []                           # надгробие второй раз не трогается
    assert spk.list_sidecars(cfg) == [fresh / spk.FILE_NAME]
    assert spk.sweep(Config(inbox="i", output="o", processed="p", failed="f",
                            service=tmp_path / "nope")) == []


def test_pick_clip_windows_spread_over_timeline():
    turns = [{"start": float(i * 10), "end": float(i * 10 + 5), "speaker": "S"} for i in range(10)]
    windows = spk.pick_clip_windows(turns)
    assert len(windows) == 3
    starts = [a for a, _ in windows]
    assert starts[0] < 30 and 40 <= starts[1] <= 60 and starts[2] > 70   # начало, середина, конец
    assert all(b - a <= spk.CLIP_SEC + 1e-9 for a, b in windows)
    assert spk.pick_clip_windows([]) == []


def test_forget_removes_recording_dir_only(tmp_path):
    cfg = make_cfg(tmp_path)
    outputs = _outputs(tmp_path)
    spk.write(cfg, tmp_path / "missing.m4a", period="2026-09", base="rec", outputs=outputs,
              turns=TURNS, centroids=CENTROIDS, names=NAMES, idents=IDENTS, segments=SEGMENTS)
    d = spk.sidecar_dir(cfg, "2026-09", "rec")
    removed = spk.forget(d)                              # каталог вместо файла тоже принимается
    assert removed == d and d.exists()                   # надгробие, а не пустое место
    stone = spk.load(d / spk.FILE_NAME)
    assert stone["removed"] == "forgotten"
    assert all(c["embedding"] is None and c["clips"] == [] for c in stone["clusters"])
    assert not (d / "clips").exists()
    assert spk.pending_count(stone) == 0 and spk.list_sidecars(cfg) == []
    assert outputs["txt"].exists()                       # транскрипт на месте
