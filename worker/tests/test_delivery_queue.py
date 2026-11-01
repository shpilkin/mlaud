"""Очередь недоставленного: постановка, автоповтор, дедуп, отбраковка исчезнувших."""

from types import SimpleNamespace

from mlaud_worker import delivery_queue as dq


def _cfg(tmp_path):
    svc = tmp_path / "service"
    svc.mkdir()
    return SimpleNamespace(service=svc)


def test_enqueue_and_dedup(tmp_path):
    cfg = _cfg(tmp_path)
    t = tmp_path / "a.txt"
    t.write_text("hi")
    dq.enqueue(cfg, t, "a")
    dq.enqueue(cfg, t, "a")  # повтор того же пути — без дубля
    assert dq.count(cfg) == 1
    assert dq.pending_bases(cfg) == ["a"]


def test_flush_resends_and_clears(tmp_path):
    cfg = _cfg(tmp_path)
    t = tmp_path / "a.txt"
    t.write_text("hi")
    dq.enqueue(cfg, t, "a")

    calls = []
    def deliver(notifier, path, base):
        calls.append(base)
        return "sent"

    res = dq.flush(cfg, notifier=object(), deliver=deliver)
    assert res["resent"] == ["a"]
    assert res["still_pending"] == []
    assert dq.count(cfg) == 0
    assert calls == ["a"]


def test_flush_keeps_still_failing(tmp_path):
    cfg = _cfg(tmp_path)
    t = tmp_path / "a.txt"
    t.write_text("hi")
    dq.enqueue(cfg, t, "a")

    res = dq.flush(cfg, notifier=object(),
                   deliver=lambda n, p, b: "failed: timeout")
    assert res["resent"] == []
    assert res["still_pending"] == ["a"]
    assert dq.count(cfg) == 1  # осталось ждать следующего раза


def test_flush_gives_up_after_max_attempts(tmp_path):
    """Всего MAX_ATTEMPTS отправок, считая первичную: enqueue(1) + два досыла."""
    cfg = _cfg(tmp_path)
    t = tmp_path / "a.txt"
    t.write_text("hi")
    dq.enqueue(cfg, t, "a")

    sends = []
    def deliver(notifier, path, base):
        sends.append(base)
        return "failed: timeout"

    r1 = dq.flush(cfg, notifier=object(), deliver=deliver)
    assert r1["given_up"] == [] and dq.count(cfg) == 1

    r2 = dq.flush(cfg, notifier=object(), deliver=deliver)
    assert r2["still_pending"] == []
    assert r2["given_up"] == [{"base": "a", "txt": str(t)}]
    assert dq.count(cfg) == 0  # больше не досылаем

    assert dq.flush(cfg, notifier=object(), deliver=deliver)["given_up"] == []
    assert len(sends) == dq.MAX_ATTEMPTS - 1  # первичная отправка была вне очереди


def test_flush_counts_legacy_entry_without_attempts(tmp_path):
    """Запись из очереди, созданной до появления счётчика: первичная попытка была."""
    cfg = _cfg(tmp_path)
    t = tmp_path / "a.txt"
    t.write_text("hi")
    dq._save(cfg, [{"txt": str(t), "base": "a", "failed_at": "2026-08-17T10:00:00"}])

    dq.flush(cfg, notifier=object(), deliver=lambda n, p, b: "failed: timeout")
    r2 = dq.flush(cfg, notifier=object(), deliver=lambda n, p, b: "failed: timeout")
    assert [g["base"] for g in r2["given_up"]] == ["a"]


def test_flush_without_notifier_does_not_burn_attempts(tmp_path):
    cfg = _cfg(tmp_path)
    t = tmp_path / "a.txt"
    t.write_text("hi")
    dq.enqueue(cfg, t, "a")
    for _ in range(5):
        dq.flush(cfg, notifier=None, deliver=lambda n, p, b: "sent")
    assert dq.count(cfg) == 1  # отправки не было — попытки не тратятся


def test_flush_drops_missing_file(tmp_path):
    cfg = _cfg(tmp_path)
    missing = tmp_path / "gone.txt"
    dq.enqueue(cfg, missing, "gone")  # файла нет на диске
    res = dq.flush(cfg, notifier=object(), deliver=lambda n, p, b: "sent")
    assert res == {"resent": [], "still_pending": [], "given_up": []}
    assert dq.count(cfg) == 0  # исчезнувший источник выброшен


def test_flush_without_notifier_keeps_queue(tmp_path):
    cfg = _cfg(tmp_path)
    t = tmp_path / "a.txt"
    t.write_text("hi")
    dq.enqueue(cfg, t, "a")
    res = dq.flush(cfg, notifier=None, deliver=lambda n, p, b: "sent")
    assert res["still_pending"] == ["a"]
    assert dq.count(cfg) == 1  # без notifier'а не теряем очередь
