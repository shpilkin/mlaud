"""База голосов: хранилище и CLI enrollment (диаризатор поддельный, pyannote не нужен)."""

import json

import numpy as np
import pytest

from mlaud_worker import voices
from mlaud_worker.config import Config
from mlaud_worker.voices import VoiceStore

DIM = 8


def unit(i, scale=2.5):
    v = np.zeros(DIM, dtype=np.float32)
    v[i] = scale
    return v


def make_cfg(tmp_path) -> Config:
    return Config(inbox=tmp_path / "in", output=tmp_path / "out", processed=tmp_path / "p",
                  failed=tmp_path / "f", service=tmp_path / "s",
                  voices_dir=tmp_path / "voices", identify=True)


# --- хранилище ---


def test_store_add_list_gallery(tmp_path):
    store = VoiceStore(tmp_path / "voices")
    assert store.people() == {} and store.gallery() == {}

    a1 = store.add("Милана Г", unit(0), source_file="a.m4a", label="SPEAKER_00",
                   speech_sec=120.0, channel="phone")
    a2 = store.add("Милана Г", unit(1), source_file="b.m4a", label="SPEAKER_03",
                   speech_sec=45.0, channel="vks")
    b1 = store.add("я", unit(2), source_file="a.m4a", label="SPEAKER_01", speech_sec=300.0)

    people = store.people()
    assert people["Милана Г"]["samples"] == [a1, a2]
    assert people["я"]["samples"] == [b1]
    assert (tmp_path / "voices/samples" / f"{a1}.npy").exists()
    meta = json.loads((tmp_path / "voices/samples" / f"{a1}.json").read_text("utf-8"))
    assert meta["person"] == "Милана Г" and meta["channel"] == "phone"
    assert meta["label"] == "SPEAKER_00" and meta["speech_sec"] == 120.0
    # образцы лежат сырыми (как отдал pyannote), не нормированными
    assert np.allclose(np.load(tmp_path / "voices/samples" / f"{a1}.npy"), unit(0))

    g = store.gallery()
    assert set(g) == {"Милана Г", "я"}
    assert np.allclose(g["Милана Г"], (unit(0) + unit(1)) / np.linalg.norm(unit(0) + unit(1)))
    assert np.allclose(np.linalg.norm(g["я"]), 1.0)

    # переоткрытие читает то же самое
    assert VoiceStore(tmp_path / "voices").people() == people


def test_store_dirs_are_private(tmp_path):
    """Биометрия: и корень, и samples/ создаются 0700, а не 755 «как родитель»."""
    store = VoiceStore(tmp_path / "deep" / "voices")
    store.add("A", unit(0), source_file="a", label="S", speech_sec=60)
    assert (store.root.stat().st_mode & 0o777) == 0o700
    assert (store.samples_dir.stat().st_mode & 0o777) == 0o700


def test_store_rejects_bad_input(tmp_path):
    store = VoiceStore(tmp_path / "voices")
    with pytest.raises(ValueError):
        store.add("A", np.zeros(DIM), source_file="a", label="S", speech_sec=60)
    with pytest.raises(ValueError):
        store.add("A", unit(0), source_file="a", label="S", speech_sec=60, channel="radio")
    with pytest.raises(ValueError):
        store.add("   ", unit(0), source_file="a", label="S", speech_sec=60)
    assert store.people() == {}


def test_store_remove_sample_and_person_deletes_files(tmp_path):
    store = VoiceStore(tmp_path / "voices")
    a1 = store.add("A", unit(0), source_file="a", label="S0", speech_sec=60)
    a2 = store.add("A", unit(1), source_file="b", label="S1", speech_sec=60)
    b1 = store.add("B", unit(2), source_file="a", label="S2", speech_sec=60)

    assert store.remove_sample(a1) == "A"
    assert store.remove_sample(a1) is None                   # уже нет
    assert not (store.samples_dir / f"{a1}.npy").exists()
    assert not (store.samples_dir / f"{a1}.json").exists()
    assert store.people()["A"]["samples"] == [a2]

    assert store.remove_person("A") == 1
    with pytest.raises(KeyError):
        store.remove_person("A")
    assert "A" not in store.people()
    assert not (store.samples_dir / f"{a2}.npy").exists()   # удаление полное
    assert (store.samples_dir / f"{b1}.npy").exists()       # чужое не тронуто
    assert list(store.gallery()) == ["B"]


def test_store_gallery_skips_samples_without_vector(tmp_path):
    store = VoiceStore(tmp_path / "voices")
    a1 = store.add("A", unit(0), source_file="a", label="S0", speech_sec=60)
    (store.samples_dir / f"{a1}.npy").unlink()
    assert store.gallery() == {}
    assert store.samples("A")[0]["id"] == a1               # метаданные ещё видны


# --- CLI ---

TURNS = [
    {"start": 0.0, "end": 40.0, "speaker": "SPEAKER_01"},    # первый по времени → «Спикер 1»
    {"start": 40.5, "end": 45.5, "speaker": "SPEAKER_00"},   # 5 c — короткий
    {"start": 46.0, "end": 100.0, "speaker": "SPEAKER_01"},
]
CENTROIDS = {"SPEAKER_00": unit(3), "SPEAKER_01": unit(0), "SPEAKER_02": np.zeros(DIM, np.float32)}


class FakeDiarizer:
    def __init__(self, turns=TURNS, centroids=CENTROIDS):
        self.turns, self.centroids = turns, centroids
        self.calls = []

    def diarize(self, path, num_speakers=None):
        self.calls.append((path, num_speakers))
        return list(self.turns), dict(self.centroids)


@pytest.fixture
def audio(tmp_path):
    p = tmp_path / "2026-06-21_rec.m4a"
    p.write_bytes(b"x")
    return p


def test_enroll_by_transcript_label_then_recognized(tmp_path, audio, capsys):
    cfg = make_cfg(tmp_path)
    fake = FakeDiarizer()
    code = voices.main(["enroll", str(audio), "Спикер 1", "Милана Г", "--channel", "phone"],
                       cfg=cfg, diarizer=fake)
    out = capsys.readouterr()
    assert code == 0, out.err
    assert "«Милана Г» ← Спикер 1 (SPEAKER_01)" in out.out
    assert fake.calls == [(str(audio), None)]

    store = VoiceStore(cfg.voices_dir)
    s = store.samples("Милана Г")
    assert len(s) == 1 and s[0]["label"] == "SPEAKER_01" and s[0]["channel"] == "phone"
    assert s[0]["speech_sec"] == pytest.approx(94.0)
    assert s[0]["source_file"] == audio.name

    # show: тот же файл теперь узнаётся
    assert voices.main(["show", str(audio)], cfg=cfg, diarizer=fake) == 0
    out = capsys.readouterr().out
    assert "Спикер 1   SPEAKER_01" in out and "Милана Г  1.000" in out
    assert "Спикер 2   SPEAKER_00" in out and "меньше 30 c речи" in out


def test_enroll_accepts_raw_label_and_bare_number(tmp_path, audio):
    cfg = make_cfg(tmp_path)
    assert voices.main(["enroll", str(audio), "SPEAKER_01", "A"], cfg=cfg, diarizer=FakeDiarizer()) == 0
    assert voices.main(["enroll", str(audio), "1", "A"], cfg=cfg, diarizer=FakeDiarizer()) == 0
    assert len(VoiceStore(cfg.voices_dir).samples("A")) == 2


def test_enroll_refuses_short_cluster(tmp_path, audio, capsys):
    cfg = make_cfg(tmp_path)
    code = voices.main(["enroll", str(audio), "Спикер 2", "Кто-то"], cfg=cfg, diarizer=FakeDiarizer())
    err = capsys.readouterr().err
    assert code == 1
    assert "5 c речи" in err and "≥ 30 c" in err
    assert VoiceStore(cfg.voices_dir).people() == {}


def test_enroll_refuses_padded_cluster(tmp_path, audio, capsys):
    turns = TURNS + [{"start": 100.0, "end": 140.0, "speaker": "SPEAKER_02"}]
    cfg = make_cfg(tmp_path)
    code = voices.main(["enroll", str(audio), "SPEAKER_02", "Кто-то"],
                       cfg=cfg, diarizer=FakeDiarizer(turns=turns))
    assert code == 1
    assert "нет эмбеддинга" in capsys.readouterr().err


def test_enroll_unknown_cluster_prints_table(tmp_path, audio, capsys):
    cfg = make_cfg(tmp_path)
    code = voices.main(["enroll", str(audio), "Спикер 9", "A"], cfg=cfg, diarizer=FakeDiarizer())
    err = capsys.readouterr().err
    assert code == 2
    assert "не найден" in err and "Спикер 1   SPEAKER_01" in err and "база пуста" in err


def test_enroll_missing_audio(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    assert voices.main(["enroll", str(tmp_path / "nope.m4a"), "1", "A"], cfg=cfg,
                       diarizer=FakeDiarizer()) == 2
    assert "нет файла" in capsys.readouterr().err


def test_list_and_remove_cli(tmp_path, audio, capsys):
    cfg = make_cfg(tmp_path)
    assert voices.main(["list"], cfg=cfg) == 0
    assert "пуста" in capsys.readouterr().out

    voices.main(["enroll", str(audio), "1", "A"], cfg=cfg, diarizer=FakeDiarizer())
    voices.main(["enroll", str(audio), "1", "B"], cfg=cfg, diarizer=FakeDiarizer())
    capsys.readouterr()
    store = VoiceStore(cfg.voices_dir)
    sid = store.samples("A")[0]["id"]

    assert voices.main(["list"], cfg=cfg) == 0
    out = capsys.readouterr().out
    assert "A: 1 образц." in out and sid in out and audio.name in out

    assert voices.main(["remove", "--sample", sid], cfg=cfg) == 0
    assert voices.main(["remove", "--sample", sid], cfg=cfg) == 1     # повторно — нет
    assert voices.main(["remove", "--person", "B"], cfg=cfg) == 0
    assert voices.main(["remove", "--person", "B"], cfg=cfg) == 1
    assert store.people() == {"A": {"created": store.people()["A"]["created"], "samples": []}}
    assert list(store.samples_dir.glob("*")) == []


# --- команды поверх сайдкара (окно «Голоса») ---

from mlaud_worker import speakers as spk


def _sidecar(tmp_path, cfg, match=None):
    txt, srt = tmp_path / "rec.txt", tmp_path / "rec.srt"
    written = "Милана Г(?)" if match else "Спикер 1"
    txt.write_text(f"[00:00:00] {written}: привет\n[00:00:41] Спикер 2: угу\n", "utf-8")
    srt.write_text(f"1\n00:00:00,000 --> 00:00:01,000\n{written}: привет\n", "utf-8")
    d = spk.sidecar_dir(cfg, "2026-09", "rec")
    sidecar = {
        "version": 1, "source": "rec.m4a", "base": "rec", "period": "2026-09",
        "processed_at": "2026-09-03T10:00:00+00:00", "txt": str(txt), "srt": str(srt),
        "duration_sec": 60.0, "threshold": 0.75, "min_speech": 30.0,
        "clusters": [
            {"label": "SPEAKER_01", "display": "Спикер 1", "speech_sec": 54.0, "first_at": 0.0,
             "n_turns": 2, "quote": "привет", "clips": [], "embedding": unit(0).tolist(),
             "match": match, "written": written, "assigned": None, "dismissed": False,
             "rejected": []},
            {"label": "SPEAKER_00", "display": "Спикер 2", "speech_sec": 5.0, "first_at": 40.5,
             "n_turns": 1, "quote": "угу", "clips": [], "embedding": unit(1).tolist(),
             "match": None, "written": "Спикер 2", "assigned": None, "dismissed": False,
             "rejected": []},
        ],
    }
    path = d / spk.FILE_NAME
    spk.save(path, sidecar)
    return path


def test_assign_name_enrolls_from_sidecar(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg)
    assert voices.main(["assign", str(path), "Спикер 1", "--name", "Милана Г", "--channel", "vks"],
                       cfg=cfg) == 0
    out = capsys.readouterr().out
    assert "«Милана Г» ← Спикер 1 (SPEAKER_01)" in out and "к разметке: 0" in out
    s = VoiceStore(cfg.voices_dir).samples("Милана Г")
    assert len(s) == 1 and s[0]["channel"] == "vks" and s[0]["source_file"] == "rec.m4a"
    assert s[0]["label"] == "SPEAKER_01" and s[0]["speech_sec"] == 54.0
    c = spk.load(path)["clusters"][0]
    assert c["assigned"] == "Милана Г" and spk.current_name(c) == "Милана Г"
    # транскрипт переподписан сразу, без отдельной кнопки
    assert (tmp_path / "rec.txt").read_text("utf-8").startswith("[00:00:00] Милана Г: привет")
    assert c["written"] == "Милана Г"
    # каталог записи принимается вместо файла
    assert voices.main(["assign", str(path.parent), "1", "--none"], cfg=cfg) == 0
    assert spk.load(path)["clusters"][0]["dismissed"] is True


def test_assign_short_cluster_names_transcript_only(tmp_path, capsys):
    """Короткому кластеру имя ставится в транскрипт, но образец в базу не идёт (FR-8.9)."""
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg)
    assert voices.main(["assign", str(path), "Спикер 2", "--name", "Гость"], cfg=cfg) == 0
    out = capsys.readouterr().out
    assert "только в транскрипт" in out and "5 c речи" in out
    assert VoiceStore(cfg.voices_dir).people() == {}
    c = spk.load(path)["clusters"][1]
    assert c["assigned"] == "Гость" and spk.current_name(c) == "Гость"
    assert "[00:00:41] Гость: угу" in (tmp_path / "rec.txt").read_text("utf-8")


def test_assign_refuses_bad_name(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg)
    assert voices.main(["assign", str(path), "Спикер 1", "--name", "Имя: с двоеточием"], cfg=cfg) == 1
    assert "двоеточие" in capsys.readouterr().err
    assert voices.main(["assign", str(path), "Спикер 9", "--name", "A"], cfg=cfg) == 2
    assert voices.main(["assign", str(tmp_path / "nope.json"), "1", "--none"], cfg=cfg) == 2
    assert VoiceStore(cfg.voices_dir).people() == {}


def test_assign_reject_and_confirm_unsure(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    match = {"name": "Милана Г", "score": 0.77, "sure": False}
    path = _sidecar(tmp_path, cfg, match=match)
    assert spk.pending_count(spk.load(path)) == 1

    # «Нет»: имя снято, кластер остаётся к разметке
    assert voices.main(["assign", str(path), "Спикер 1", "--reject"], cfg=cfg) == 0
    c = spk.load(path)["clusters"][0]
    assert c["rejected"] == ["Милана Г"] and spk.current_name(c) == "Спикер 1"
    assert spk.pending_count(spk.load(path)) == 1

    # «Да, он»: образец в базу, имя без (?) и снято из отклонённых
    assert voices.main(["assign", str(path), "Спикер 1", "--name", "Милана Г"], cfg=cfg) == 0
    c = spk.load(path)["clusters"][0]
    assert c["assigned"] == "Милана Г" and c["rejected"] == []
    assert len(VoiceStore(cfg.voices_dir).samples("Милана Г")) == 1
    assert spk.pending_count(spk.load(path)) == 0


def test_relabel_cli(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg, match={"name": "Милана Г", "score": 0.77, "sure": False})
    voices.main(["assign", str(path), "1", "--name", "Милана Г"], cfg=cfg)
    assert "транскрипт переподписан: строк 2" in capsys.readouterr().out
    assert (tmp_path / "rec.txt").read_text("utf-8").startswith("[00:00:00] Милана Г: привет")
    # кнопка «Переподписать» после этого — холостая, но безвредная
    assert voices.main(["relabel", str(path)], cfg=cfg) == 0
    assert "уже с текущими" in capsys.readouterr().out
    # правка файла снаружи → кнопка возвращает имена
    (tmp_path / "rec.txt").write_text("[00:00:00] Спикер 1: привет\n", "utf-8")
    sidecar = spk.load(path)
    sidecar["clusters"][0]["written"] = "Спикер 1"
    spk.save(path, sidecar)
    assert voices.main(["relabel", str(path)], cfg=cfg) == 0
    assert "переподписано строк: 1" in capsys.readouterr().out


def test_resend_cli(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg)

    class Notifier:
        sent = []

        def send_document(self, file_path, caption=None):
            self.sent.append((str(file_path), caption))

    class Broken(Notifier):
        def send_document(self, file_path, caption=None):
            raise RuntimeError("timeout https://api.telegram.org/bot123456789:AAHfW3xSECRETSECRETSECRET12/x")

    assert voices.main(["resend", str(path)], cfg=cfg, notifier=Notifier()) == 0
    assert Notifier.sent == [(str(tmp_path / "rec.txt"), "rec")]
    assert voices.main(["resend", str(path)], cfg=cfg, notifier=Broken()) == 1
    err = capsys.readouterr().err
    assert "не отправлено" in err and "SECRET" not in err        # токен замаскирован


def test_rename_updates_store_and_sidecars(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg, match={"name": "Милана Г", "score": 0.9, "sure": True})
    voices.main(["assign", str(path), "1", "--name", "Милана Г"], cfg=cfg)
    capsys.readouterr()
    assert voices.main(["rename", "Милана Г", "Милана Галкина"], cfg=cfg) == 0
    assert "записей затронуто: 1" in capsys.readouterr().out
    store = VoiceStore(cfg.voices_dir)
    assert list(store.people()) == ["Милана Галкина"]
    assert store.samples("Милана Галкина")[0]["person"] == "Милана Галкина"
    c = spk.load(path)["clusters"][0]
    assert c["assigned"] == "Милана Галкина" and c["match"]["name"] == "Милана Галкина"
    assert voices.main(["rename", "Нет такого", "X"], cfg=cfg) == 1
    voices.main(["assign", str(path), "1", "--name", "Другой"], cfg=cfg)
    assert voices.main(["rename", "Другой", "Милана Галкина"], cfg=cfg) == 1   # занято


def test_list_json(tmp_path, capsys):
    import json as _json

    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg)
    voices.main(["assign", str(path), "1", "--name", "Милана Г", "--channel", "phone"], cfg=cfg)
    capsys.readouterr()
    assert voices.main(["list", "--json"], cfg=cfg) == 0
    payload = _json.loads(capsys.readouterr().out)
    assert payload["root"] == str(cfg.voices_dir)
    assert [p["name"] for p in payload["people"]] == ["Милана Г"]
    sample = payload["people"][0]["samples"][0]
    assert sample["channel"] == "phone" and "id" in sample and sample["source_file"] == "rec.m4a"


# --- prepare: разметить старую запись ---

WORDS = [
    {"start": 0.0, "end": 0.5, "text": "привет"},
    {"start": 0.5, "end": 1.0, "text": "всем"},
    {"start": 41.0, "end": 41.5, "text": "угу"},
]


class FakeTranscriber:
    def transcribe_words(self, path):
        return list(WORDS)

    def transcribe(self, path):
        raise AssertionError("prepare всегда идёт через диаризацию")


def test_prepare_writes_transcript_and_sidecar_without_moving(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    archive = cfg.processed / "2026-08"
    archive.mkdir(parents=True)
    audio = archive / "2026-08-28_rec.m4a"
    audio.write_bytes(b"x")
    # в базе есть голос SPEAKER_01 → имя подставится сразу
    VoiceStore(cfg.voices_dir).add("Милана Г", unit(0), source_file="old.m4a", label="S", speech_sec=100)

    code = voices.main(["prepare", str(audio)], cfg=cfg, diarizer=FakeDiarizer(),
                       transcriber=FakeTranscriber())
    out = capsys.readouterr().out
    assert code == 0 and "готово: 2026-08-28_rec — 2 реплик, к разметке: 0" in out
    assert audio.exists()                                          # файл не перенесён
    txt = cfg.output / "2026-08" / "2026-08-28_rec.txt"            # месяц — из папки архива
    assert txt.read_text("utf-8") == "[00:00:00] Милана Г: привет всем\n[00:00:41] Спикер 2: угу\n"
    sidecar = spk.load(spk.sidecar_dir(cfg, "2026-08", "2026-08-28_rec") / spk.FILE_NAME)
    assert sidecar["txt"] == str(txt) and sidecar["clusters"][0]["written"] == "Милана Г"
    assert not (cfg.service / "pending_delivery.json").exists()    # доставки не было


def test_prepare_reuses_existing_transcript_folder(tmp_path):
    cfg = make_cfg(tmp_path)
    audio = cfg.processed / "2026-08" / "rec.m4a"
    audio.parent.mkdir(parents=True)
    audio.write_bytes(b"x")
    old = cfg.output / "2026-07" / "rec.txt"            # старый прогон положил в другой месяц
    old.parent.mkdir(parents=True)
    old.write_text("старое", "utf-8")
    assert voices.main(["prepare", str(audio)], cfg=cfg, diarizer=FakeDiarizer(),
                       transcriber=FakeTranscriber()) == 0
    assert old.read_text("utf-8").startswith("[00:00:00] Спикер 1: привет всем")
    assert not (cfg.output / "2026-08").exists()
    assert (spk.sidecar_dir(cfg, "2026-07", "rec") / spk.FILE_NAME).exists()


def test_prepare_refuses_call_recording_with_channels_sidecar(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    audio = cfg.processed / "2026-09" / "2026-09-04_15-30-05.m4a"
    audio.parent.mkdir(parents=True)
    audio.write_bytes(b"x")
    audio.with_name("2026-09-04_15-30-05.channels.json").write_text(
        '{"version":1,"call_id":"2026-09-04_15-30-05","channels":{"0":"Я","1":"Собеседник"}}', "utf-8")
    assert voices.main(["prepare", str(audio)], cfg=cfg, diarizer=FakeDiarizer(),
                       transcriber=FakeTranscriber()) == 2
    assert "запись звонка" in capsys.readouterr().err
    assert not cfg.output.exists() and not (cfg.service / "speakers").exists()


def test_prepare_prefers_audio_month_when_base_repeats(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    for month in ("2026-06", "2026-08"):
        t = cfg.output / month / "rec.txt"
        t.parent.mkdir(parents=True)
        t.write_text(f"старое {month}", "utf-8")
    audio = cfg.processed / "2026-08" / "rec.m4a"
    audio.parent.mkdir(parents=True)
    audio.write_bytes(b"x")
    assert voices.main(["prepare", str(audio)], cfg=cfg, diarizer=FakeDiarizer(),
                       transcriber=FakeTranscriber()) == 0
    assert (cfg.output / "2026-08" / "rec.txt").read_text("utf-8").startswith("[00:00:00]")
    assert (cfg.output / "2026-06" / "rec.txt").read_text("utf-8") == "старое 2026-06"
    assert (spk.sidecar_dir(cfg, "2026-08", "rec") / spk.FILE_NAME).exists()
    # Аудио из третьего месяца при двух транскриптах — отказ, а не молчаливый выбор.
    other = cfg.processed / "2026-05" / "rec.m4a"
    other.parent.mkdir(parents=True)
    other.write_bytes(b"x")
    assert voices.main(["prepare", str(other)], cfg=cfg, diarizer=FakeDiarizer(),
                       transcriber=FakeTranscriber()) == 2
    assert "не знаю, какой перезаписывать" in capsys.readouterr().err
    assert (cfg.output / "2026-06" / "rec.txt").read_text("utf-8") == "старое 2026-06"


def test_prepare_period_fallback_and_missing_file(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    loose = tmp_path / "loose"
    loose.mkdir()
    audio = loose / "2026-06-21_rec.m4a"                           # папка не месяц → из имени
    audio.write_bytes(b"x")
    code = voices.main(["prepare", str(audio), str(loose / "nope.m4a")], cfg=cfg,
                       diarizer=FakeDiarizer(), transcriber=FakeTranscriber())
    err = capsys.readouterr().err
    assert code == 2 and "нет файла" in err
    assert (cfg.output / "2026-06" / "2026-06-21_rec.txt").exists()
    assert spk.pending_count(spk.load(spk.sidecar_dir(cfg, "2026-06", "2026-06-21_rec") / spk.FILE_NAME)) == 1


def test_assign_mixed_and_restore(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg, match={"name": "Милана Г", "score": 0.77, "sure": False})
    assert voices.main(["assign", str(path), "1", "--mixed"], cfg=cfg) == 0
    c = spk.load(path)["clusters"][0]
    assert c["mixed"] is True and c["dismissed"] is True
    assert spk.current_name(c) == "Спикер 1 (смесь голосов)"
    assert spk.pending_count(spk.load(path)) == 0
    # пометка дошла до транскрипта
    assert (tmp_path / "rec.txt").read_text("utf-8").startswith("[00:00:00] Спикер 1 (смесь голосов): привет")
    assert voices.main(["assign", str(path), "1", "--restore"], cfg=cfg) == 0
    c = spk.load(path)["clusters"][0]
    assert c["mixed"] is False and c["dismissed"] is False
    assert spk.pending_count(spk.load(path)) == 1
    assert VoiceStore(cfg.voices_dir).people() == {}       # смесь в базу не попала
    # и суффикс из транскрипта ушёл вместе с пометкой
    assert (tmp_path / "rec.txt").read_text("utf-8").startswith("[00:00:00] Милана Г(?): привет")


def test_forget_cli(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg)
    assert voices.main(["forget", str(path.parent)], cfg=cfg) == 0
    assert "убрано из разметки: rec" in capsys.readouterr().out
    assert spk.load(path)["removed"] == "forgotten" and (tmp_path / "rec.txt").exists()
    assert voices.main(["forget", str(path)], cfg=cfg) == 0        # повтор безвреден
    assert voices.main(["forget", str(tmp_path / "нет")], cfg=cfg) == 2


# --- перенос разметки замера и пересчёт подсказок ---


def _eval_dir(tmp_path):
    import json as _json

    root = tmp_path / "spkid-eval"
    data = root / "data"
    data.mkdir(parents=True)

    def rec(slug, name, duration, speakers, vecs):
        (data / f"{slug}.json").write_text(_json.dumps({
            "slug": slug, "name": name, "duration": duration,
            "speakers": [{"label": lab, "index": i, "speech_sec": sec, "padded": pad}
                         for i, (lab, sec, pad) in enumerate(speakers)],
        }, ensure_ascii=False), "utf-8")
        np.save(data / f"{slug}.npy", np.stack(vecs).astype(np.float32))

    rec("a__1", "a.m4a", 800.4,
        [("SPEAKER_00", 120.0, False), ("SPEAKER_01", 12.0, False), ("SPEAKER_02", 90.0, False),
         ("SPEAKER_03", 60.0, True)],
        [unit(0), unit(1), unit(2), np.zeros(DIM, np.float32)])
    rec("a2__2", "a.mp3", 800.0, [("SPEAKER_00", 120.0, False)], [unit(0)])   # та же встреча
    rec("b__3", "b.m4a", 300.0, [("SPEAKER_00", 45.0, False), ("SPEAKER_01", 200.0, False)],
        [unit(3), unit(4)])
    (root / "labels.json").write_text(_json.dumps({
        "speakers": {
            "a__1|SPEAKER_00": {"name": "я", "mixed": False},
            "a__1|SPEAKER_01": {"name": "Кира Л", "mixed": False},      # короткий
            "a__1|SPEAKER_02": {"name": "", "mixed": True},             # смесь
            "a__1|SPEAKER_03": {"name": "Ося К", "mixed": False},       # добивка
            "a2__2|SPEAKER_00": {"name": "Я", "mixed": False},
            "b__3|SPEAKER_00": {"name": "я", "mixed": False},
            "b__3|SPEAKER_01": {"name": "Демид К", "mixed": False},
        },
        "channels": {"a__1": "phone", "b__3": ""},
    }, ensure_ascii=False), "utf-8")
    return root


def test_import_eval_follows_measurement_rules_and_is_idempotent(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    root = _eval_dir(tmp_path)
    assert voices.main(["import-eval", str(root)], cfg=cfg) == 0
    out = capsys.readouterr().out
    assert "добавлено образцов: 3 у 2 чел." in out
    store = VoiceStore(cfg.voices_dir)
    assert sorted(store.people()) == ["Демид К", "я"]
    me = store.samples("я")
    assert {s["source_file"] for s in me} == {"a.m4a", "b.m4a"}     # a.mp3 — дубль встречи
    assert {s["channel"] for s in me} == {"phone", "other"}
    assert len(store.samples("Демид К")) == 1
    # повтор ничего не добавляет
    assert voices.main(["import-eval", str(root)], cfg=cfg) == 0
    assert "добавлено образцов: 0" in capsys.readouterr().out
    assert len(store.samples()) == 3
    assert voices.main(["import-eval", str(tmp_path / "nope")], cfg=cfg) == 2


def test_assign_rematches_other_recordings(tmp_path, capsys):
    cfg = make_cfg(tmp_path)
    first = _sidecar(tmp_path, cfg)                        # rec: SPEAKER_01 = unit(0)
    # вторая запись с тем же голосом, пока без подсказки
    second_dir = spk.sidecar_dir(cfg, "2026-09", "other")
    second = second_dir / spk.FILE_NAME
    other = spk.load(first)
    other["base"], other["source"] = "other", "other.m4a"
    other["txt"], other["srt"] = str(tmp_path / "o.txt"), ""
    spk.save(second, other)
    assert spk.load(second)["clusters"][0]["match"] is None

    assert voices.main(["assign", str(first), "1", "--name", "Милана Г"], cfg=cfg) == 0
    got = spk.load(second)["clusters"][0]["match"]
    assert got and got["name"] == "Милана Г" and got["sure"] is True
    assert spk.load(second)["clusters"][1]["match"] is None      # короткий не сравнивался
    assert spk.pending_count(spk.load(second)) == 0

    # удалили человека — подсказка исчезла
    assert voices.main(["remove", "--person", "Милана Г"], cfg=cfg) == 0
    assert spk.load(second)["clusters"][0]["match"] is None
    assert spk.load(first)["clusters"][0]["assigned"] == "Милана Г"   # ручная разметка не тронута


def test_rematch_respects_assigned_names_in_same_file(tmp_path):
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg)
    sidecar = spk.load(path)
    # второй длинный кластер с тем же голосом, что и первый; первый уже подписан
    sidecar["clusters"][1]["speech_sec"] = 60.0
    sidecar["clusters"][1]["embedding"] = unit(0).tolist()
    sidecar["clusters"][0]["assigned"] = "Милана Г"
    spk.save(path, sidecar)
    VoiceStore(cfg.voices_dir).add("Милана Г", unit(0), source_file="x", label="S", speech_sec=100)
    assert voices.main(["rematch", str(path)], cfg=cfg) == 0
    assert spk.load(path)["clusters"][1]["match"] is None        # имя уже занято в этом файле


def test_assign_delete_hides_cluster_and_restore_brings_back(tmp_path):
    cfg = make_cfg(tmp_path)
    path = _sidecar(tmp_path, cfg, match={"name": "Милана Г", "score": 0.77, "sure": False})
    assert voices.main(["assign", str(path), "1", "--delete"], cfg=cfg) == 0
    c = spk.load(path)["clusters"][0]
    assert c["hidden"] is True and c["assigned"] is None
    assert spk.current_name(c) == "Спикер 1" and spk.pending_count(spk.load(path)) == 0
    assert voices.main(["assign", str(path), "1", "--restore"], cfg=cfg) == 0
    c = spk.load(path)["clusters"][0]
    assert c["hidden"] is False and spk.pending_count(spk.load(path)) == 1
