"""Тесты оркестрации: фильтрация inbox, lock, end-to-end и идемпотентность."""

import shutil
from pathlib import Path

import pytest

from mlaud_worker.config import Config
from mlaud_worker.pipeline import (
    is_ready, list_audio, derive_period, file_lock, process_inbox, LockError,
)


def make_cfg(tmp_path) -> Config:
    return Config(
        inbox=tmp_path / "inbox",
        output=tmp_path / "out",
        processed=tmp_path / "processed",
        failed=tmp_path / "failed",
        service=tmp_path / "service",
        model_type="rnnt",
    )


class FakeNotifier:
    def __init__(self):
        self.docs = []
        self.messages = []
        self.errors = []

    def send_document(self, file_path, caption=None):
        self.docs.append((str(file_path), caption))
        return {"ok": True}

    def send_message(self, text):
        self.messages.append(text)
        return {"ok": True}

    def send_error(self, text):
        self.errors.append(text)
        return {"ok": True}


class FakeTranscriber:
    """Транскрайбер без модели — возвращает заранее заданные сегменты."""

    def __init__(self, segments):
        self._segments = segments

    def transcribe(self, path):
        return list(self._segments)


def test_is_ready_filters(tmp_path):
    good = tmp_path / "rec.m4a"; good.write_bytes(b"x")
    hidden = tmp_path / ".rec.m4a"; hidden.write_bytes(b"x")
    icloud = tmp_path / "rec.m4a.icloud"; icloud.write_bytes(b"x")
    empty = tmp_path / "empty.m4a"; empty.write_bytes(b"")
    assert is_ready(good) is True
    assert is_ready(hidden) is False
    assert is_ready(icloud) is False
    assert is_ready(empty) is False


def test_is_ready_skips_dataless_icloud(tmp_path):
    """Выгруженный iCloud-файл (size>0, blocks==0) не готов — ждём докачки, не падаем."""
    dataless = tmp_path / "evicted.m4a"
    with open(dataless, "wb") as f:
        f.truncate(1_000_000)        # sparse: логический размер есть, блоков нет
    st = dataless.stat()
    if getattr(st, "st_blocks", 1) != 0:
        pytest.skip("ФС не создаёт sparse-файл (нет блоков-дыр)")
    assert is_ready(dataless) is False


def test_list_audio_only_ready_audio(tmp_path):
    cfg = make_cfg(tmp_path)
    cfg.inbox.mkdir(parents=True)
    (cfg.inbox / "b.m4a").write_bytes(b"x")
    (cfg.inbox / "a.m4a").write_bytes(b"x")
    (cfg.inbox / "note.txt").write_bytes(b"x")        # не аудио
    (cfg.inbox / "c.m4a.icloud").write_bytes(b"x")    # плейсхолдер
    (cfg.inbox / ".hidden.m4a").write_bytes(b"x")     # скрытый
    names = [p.name for p in list_audio(cfg)]
    assert names == ["a.m4a", "b.m4a"]  # отсортировано, только готовые аудио


def test_derive_period_from_prefix(tmp_path):
    f = tmp_path / "2026-06-21_14-30-00.m4a"; f.write_bytes(b"x")
    assert derive_period(f) == "2026-06"  # месяц, не день


def test_derive_period_from_mtime(tmp_path):
    f = tmp_path / "Пример записи.m4a"; f.write_bytes(b"x")
    d = derive_period(f)
    assert len(d) == 7 and d[4] == "-"  # формат YYYY-MM


def test_file_lock_blocks_reentry(tmp_path):
    cfg = make_cfg(tmp_path)
    with file_lock(cfg):
        with pytest.raises(LockError):
            with file_lock(cfg):
                pass
    # после выхода lock освобождён
    with file_lock(cfg):
        pass


def test_empty_transcript_archived_no_document_no_loop(tmp_path):
    """Пустая запись: документ не шлём, шлём сообщение, файл архивируется, нет повтора."""
    cfg = make_cfg(tmp_path)
    cfg.inbox.mkdir(parents=True)
    src = cfg.inbox / "2026-06-15_silent.m4a"
    src.write_bytes(b"x")

    notifier = FakeNotifier()
    result = process_inbox(cfg, transcriber=FakeTranscriber([]), notifier=notifier)

    assert result["errors"] == []
    assert len(result["processed"]) == 1
    assert result["processed"][0]["delivery"] == "empty"
    assert notifier.docs == []            # пустой документ (0 байт) НЕ отправляли
    assert len(notifier.messages) == 1    # отправили короткое сообщение
    assert notifier.errors == []          # это не ошибка
    assert not src.exists()               # файл заархивирован
    assert (cfg.processed / "2026-06" / src.name).exists()

    # повторный прогон ничего не делает — нет бесконечного цикла
    result2 = process_inbox(cfg, transcriber=FakeTranscriber([]), notifier=notifier)
    assert result2["processed"] == []


def test_delivery_failure_still_archives_and_reports_once(tmp_path):
    """Сбой доставки (400) не блокирует архивацию и не зацикливает обработку."""
    class Failing(FakeNotifier):
        def send_document(self, file_path, caption=None):
            raise RuntimeError("400 Client Error: Bad Request")

    cfg = make_cfg(tmp_path)
    cfg.inbox.mkdir(parents=True)
    src = cfg.inbox / "2026-06-15_rec.m4a"
    src.write_bytes(b"x")

    notifier = Failing()
    segs = [{"start": 0.0, "end": 1.0, "text": "привет"}]
    result = process_inbox(cfg, transcriber=FakeTranscriber(segs), notifier=notifier)

    assert result["errors"] == []                       # доставка ≠ фатальная ошибка пакета
    assert result["processed"][0]["delivery"].startswith("failed")
    assert not src.exists()                              # заархивирован несмотря на сбой
    assert (cfg.processed / "2026-06" / src.name).exists()
    assert len(notifier.errors) == 1                    # один ⚠️, не цикл

    # повторного прогона нет
    assert process_inbox(cfg, transcriber=FakeTranscriber(segs), notifier=notifier)["processed"] == []


def test_failed_delivery_enqueued_then_redelivered(tmp_path):
    """Сбой доставки → транскрипт в очереди → следующий прогон досылает его сам."""
    cfg = make_cfg(tmp_path)
    cfg.inbox.mkdir(parents=True)
    src = cfg.inbox / "2026-06-15_rec.m4a"
    src.write_bytes(b"x")
    segs = [{"start": 0.0, "end": 1.0, "text": "привет"}]

    class Failing(FakeNotifier):
        def send_document(self, file_path, caption=None):
            raise RuntimeError("Connection to api.telegram.org timed out")

    r1 = process_inbox(cfg, transcriber=FakeTranscriber(segs), notifier=Failing())
    assert r1["processed"][0]["delivery"].startswith("failed")
    assert r1["pending"] == ["2026-06-15_rec"]      # встал в очередь

    # «сеть вернулась»: даже без новых файлов очередь досылается
    working = FakeNotifier()
    r2 = process_inbox(cfg, transcriber=FakeTranscriber(segs), notifier=working)
    assert r2["processed"] == []                     # новых файлов нет
    assert r2["redelivered"] == ["2026-06-15_rec"]   # досланный из очереди
    assert r2["pending"] == []                        # очередь пуста
    assert len(working.docs) == 1                     # ушёл файлом .txt

    # третий прогон — очередь уже пуста, повторов нет
    r3 = process_inbox(cfg, transcriber=FakeTranscriber(segs), notifier=FakeNotifier())
    assert r3["redelivered"] == [] and r3["pending"] == []


def test_failed_file_quarantined_no_infinite_retry(tmp_path):
    """Нечитаемый файл (напр. невыгруженный iCloud) уходит в карантин, не зацикливается."""
    class Broken(FakeTranscriber):
        def transcribe(self, path):
            raise RuntimeError("Error opening: unreadable audio")

    cfg = make_cfg(tmp_path)
    cfg.inbox.mkdir(parents=True)
    src = cfg.inbox / "2026-06-15_broken.m4a"
    src.write_bytes(b"x")

    notifier = FakeNotifier()
    result = process_inbox(cfg, transcriber=Broken([]), notifier=notifier)

    assert len(result["errors"]) == 1
    assert not src.exists()                                 # убрали из inbox
    assert (cfg.failed / src.name).exists()                 # в карантине
    assert len(notifier.errors) == 1                        # один ⚠️

    # повторный прогон ничего не обрабатывает — нет вечного ретрая/спама
    result2 = process_inbox(cfg, transcriber=Broken([]), notifier=notifier)
    assert result2["errors"] == []
    assert len(notifier.errors) == 1


def test_process_inbox_end_to_end_and_idempotent(tmp_path, transcriber, short_clip):
    cfg = make_cfg(tmp_path)
    cfg.inbox.mkdir(parents=True)
    src = cfg.inbox / short_clip.name
    shutil.copy(str(short_clip), str(src))

    notifier = FakeNotifier()
    result = process_inbox(cfg, transcriber=transcriber, notifier=notifier)

    assert len(result["processed"]) == 1
    assert result["errors"] == []
    r = result["processed"][0]

    # вывод создан локально, в МЕСЯЧНОЙ папке из имени файла
    assert r["txt"].exists() and r["srt"].exists()
    assert (cfg.output / "2026-06").exists()
    assert r["period"] == "2026-06"

    # транскрипт осмысленный (реальная речь)
    text = r["txt"].read_text(encoding="utf-8").lower()
    assert "развит" in text, f"не нашли ожидаемых слов в транскрипте: {text[:200]}"

    # аудио перенесено в processed (месячная папка), inbox очищен
    assert not src.exists()
    assert (cfg.processed / "2026-06" / short_clip.name).exists()

    # доставка вызвана ровно один раз файлом .txt
    assert len(notifier.docs) == 1
    assert notifier.docs[0][0] == str(r["txt"])

    # повторный прогон ничего не обрабатывает (идемпотентность)
    result2 = process_inbox(cfg, transcriber=transcriber, notifier=notifier)
    assert result2["processed"] == []
    assert result2["errors"] == []


# --- сдача артефакта роутеру ---


def test_process_writes_sidecar_and_handoff(tmp_path):
    """Конвейер оставляет описание рядом с транскриптом и json в папке обмена."""
    import json

    cfg = make_cfg(tmp_path)
    cfg.router_inbox = tmp_path / "artifacts_inbox"
    cfg.inbox.mkdir(parents=True)
    audio = cfg.inbox / "2026-08-16_14-30-05.m4a"
    audio.write_bytes(b"audio-bytes" * 100)
    tr = FakeTranscriber([{"start": 0.0, "end": 1800.0, "text": "поговорили"}])

    result = process_inbox(cfg, transcriber=tr, use_lock=False)
    assert result["errors"] == []
    r = result["processed"][0]
    assert r["artifact"] == "sent"

    sidecar = Path(str(r["txt"]).replace(".txt", ".meta.json"))
    payload = json.loads(sidecar.read_text(encoding="utf-8"))
    assert payload["duration_sec"] == 1800  # из сегментов: в файле нет метаданных m4a
    # Путь к аудио — на его архивном месте и относительно корня архива.
    assert payload["audio_path"].startswith("processed/")
    assert not Path(payload["transcript_path"]).is_absolute()

    handed = list((tmp_path / "artifacts_inbox").glob("*.json"))
    assert [p.name for p in handed] == [f"{payload['meeting_id']}.json"]


def test_handoff_failure_never_breaks_the_pipeline(tmp_path):
    """Роутер недоступен (папка обмена — это файл): транскрипт всё равно сделан,
    доставлен и заархивирован."""
    cfg = make_cfg(tmp_path)
    cfg.router_inbox = tmp_path / "not-a-dir"
    cfg.router_inbox.write_text("я файл, а не папка", encoding="utf-8")
    cfg.inbox.mkdir(parents=True)
    (cfg.inbox / "rec.m4a").write_bytes(b"x" * 10)
    notifier = FakeNotifier()

    result = process_inbox(
        cfg, transcriber=FakeTranscriber([{"start": 0, "end": 1, "text": "привет"}]),
        notifier=notifier, use_lock=False,
    )
    assert result["errors"] == []
    r = result["processed"][0]
    assert r["artifact"].startswith("failed")
    assert r["delivery"] == "sent"
    assert Path(r["archived"]).exists()


def test_sidecar_is_written_even_with_the_router_off(tmp_path):
    cfg = make_cfg(tmp_path)  # router_inbox не задан
    cfg.inbox.mkdir(parents=True)
    (cfg.inbox / "rec.m4a").write_bytes(b"x" * 10)
    result = process_inbox(
        cfg, transcriber=FakeTranscriber([{"start": 0, "end": 2, "text": "ага"}]),
        use_lock=False,
    )
    r = result["processed"][0]
    assert r["artifact"] == "sidecar"
    assert Path(str(r["txt"]).replace(".txt", ".meta.json")).exists()


def test_no_router_installed_means_no_stray_inbox(tmp_path):
    """Роутер не установлен (нет его каталога данных) — папку обмена не создаём."""
    cfg = make_cfg(tmp_path)
    cfg.router_inbox = tmp_path / "EmailReader" / "artifacts_inbox"  # родителя нет
    cfg.inbox.mkdir(parents=True)
    (cfg.inbox / "rec.m4a").write_bytes(b"x" * 10)
    result = process_inbox(
        cfg, transcriber=FakeTranscriber([{"start": 0, "end": 1, "text": "ага"}]),
        use_lock=False,
    )
    assert result["processed"][0]["artifact"] == "no-router"
    assert not (tmp_path / "EmailReader").exists()


# --- диаризация + имена (Фаза 3) ---

import numpy as np

from mlaud_worker.voices import VoiceStore


def _vec(i, dim=8, scale=2.5):
    v = np.zeros(dim, dtype=np.float32)
    v[i] = scale
    return v


class FakeWordTranscriber(FakeTranscriber):
    def __init__(self, words):
        super().__init__([])
        self._words = words

    def transcribe_words(self, path):
        return list(self._words)


class FakeDiarizer:
    def __init__(self, turns, centroids):
        self.turns, self.centroids = turns, centroids

    def diarize(self, path, num_speakers=None):
        return list(self.turns), dict(self.centroids)


TURNS = [
    {"start": 0.0, "end": 40.0, "speaker": "SPEAKER_00"},    # 40 c → достаточно для имени
    {"start": 40.5, "end": 45.5, "speaker": "SPEAKER_01"},   # 5 c → имени не будет никогда
]
WORDS = [
    {"start": 0.0, "end": 0.5, "text": "привет"},
    {"start": 0.5, "end": 1.0, "text": "всем"},
    {"start": 41.0, "end": 41.5, "text": "угу"},
]
CENTROIDS = {"SPEAKER_00": _vec(0), "SPEAKER_01": _vec(1)}


def _run_diarized(tmp_path, identify: bool, enroll: bool = True):
    cfg = make_cfg(tmp_path)
    cfg.identify = identify
    cfg.voices_dir = tmp_path / "voices"
    cfg.inbox.mkdir(parents=True)
    if enroll:
        # в базе и «Милана Г» (= SPEAKER_00), и голос короткого кластера — он всё равно
        # не должен получить имени
        store = VoiceStore(cfg.voices_dir)
        store.add("Милана Г", _vec(0), source_file="old.m4a", label="SPEAKER_02", speech_sec=200)
        store.add("Гость", _vec(1), source_file="old.m4a", label="SPEAKER_03", speech_sec=60)
    (cfg.inbox / "2026-06-21_rec.m4a").write_bytes(b"x")
    result = process_inbox(cfg, transcriber=FakeWordTranscriber(WORDS),
                           diarizer=FakeDiarizer(TURNS, CENTROIDS), use_lock=False)
    assert result["errors"] == []
    r = result["processed"][0]
    return r["txt"].read_text("utf-8"), r["srt"].read_text("utf-8"), r


def test_identify_puts_name_into_txt_and_srt(tmp_path):
    txt, srt, r = _run_diarized(tmp_path, identify=True)
    assert txt == "[00:00:00] Милана Г: привет всем\n[00:00:41] Спикер 2: угу\n"
    assert "Милана Г: привет всем" in srt and "Спикер 2: угу" in srt
    # сайдкар для окна «Голоса»: узнан уверенно → к разметке нечего
    assert r["speakers"]["status"] == "written" and r["speakers"]["pending"] == 0
    from mlaud_worker import speakers as spk
    sidecar = spk.load(Path(r["speakers"]["path"]))
    assert sidecar["source"] == "2026-06-21_rec.m4a" and sidecar["txt"] == str(r["txt"])
    assert sidecar["clusters"][0]["match"]["name"] == "Милана Г"
    assert sidecar["clusters"][0]["written"] == "Милана Г"
    assert "clips_error" in sidecar                       # аудио-заглушка не декодируется


def test_identify_off_gives_previous_output_even_with_voices_on_disk(tmp_path):
    txt, srt, r = _run_diarized(tmp_path, identify=False)
    assert txt == "[00:00:00] Спикер 1: привет всем\n[00:00:41] Спикер 2: угу\n"
    assert "Спикер 1: привет всем" in srt
    assert r["speakers"] is None                          # без идентификации сайдкара нет


def test_identify_broken_voices_index_degrades_to_speaker_n(tmp_path):
    """Испорченный index.json: транскрипт делается без имён, прогон не падает."""
    cfg = make_cfg(tmp_path)
    cfg.identify = True
    cfg.voices_dir = tmp_path / "voices"
    cfg.voices_dir.mkdir()
    (cfg.voices_dir / "index.json").write_text("{не json", encoding="utf-8")
    cfg.inbox.mkdir(parents=True)
    (cfg.inbox / "2026-06-21_rec.m4a").write_bytes(b"x")
    result = process_inbox(cfg, transcriber=FakeWordTranscriber(WORDS),
                           diarizer=FakeDiarizer(TURNS, CENTROIDS), use_lock=False)
    assert result["errors"] == []
    assert result["identify_error"]
    txt = result["processed"][0]["txt"].read_text("utf-8")
    assert txt.startswith("[00:00:00] Спикер 1: привет всем")


def test_identify_with_empty_voices_dir_is_previous_output(tmp_path):
    txt, _, r = _run_diarized(tmp_path, identify=True, enroll=False)
    assert txt == "[00:00:00] Спикер 1: привет всем\n[00:00:41] Спикер 2: угу\n"
    # пустая база: сайдкар всё равно пишется — иначе первый голос завести неоткуда
    assert r["speakers"]["status"] == "written" and r["speakers"]["pending"] == 1
