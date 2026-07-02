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


def test_flush_drops_missing_file(tmp_path):
    cfg = _cfg(tmp_path)
    missing = tmp_path / "gone.txt"
    dq.enqueue(cfg, missing, "gone")  # файла нет на диске
    res = dq.flush(cfg, notifier=object(), deliver=lambda n, p, b: "sent")
    assert res == {"resent": [], "still_pending": []}
    assert dq.count(cfg) == 0  # исчезнувший источник выброшен


def test_flush_without_notifier_keeps_queue(tmp_path):
    cfg = _cfg(tmp_path)
    t = tmp_path / "a.txt"
    t.write_text("hi")
    dq.enqueue(cfg, t, "a")
    res = dq.flush(cfg, notifier=None, deliver=lambda n, p, b: "sent")
    assert res["still_pending"] == ["a"]
    assert dq.count(cfg) == 1  # без notifier'а не теряем очередь
