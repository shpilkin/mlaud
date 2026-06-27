"""Тесты оркестрации: фильтрация inbox, lock, end-to-end и идемпотентность."""

import shutil

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
