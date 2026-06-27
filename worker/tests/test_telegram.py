"""Тесты доставки в Telegram через инъекцию sender/messenger (без сети)."""

from mlaud_worker.telegram import TelegramNotifier


def test_send_document_calls_sender(tmp_path):
    calls = []

    def fake_sender(token, chat_id, file_path, caption):
        calls.append((token, chat_id, file_path, caption))
        return {"ok": True}

    f = tmp_path / "rec.txt"
    f.write_text("hello")
    n = TelegramNotifier("TOK", "123", sender=fake_sender)
    res = n.send_document(f, caption="rec")

    assert res == {"ok": True}
    assert calls == [("TOK", "123", str(f), "rec")]


def test_send_error_calls_messenger():
    msgs = []

    def fake_messenger(token, chat_id, text):
        msgs.append((token, chat_id, text))
        return {"ok": True}

    n = TelegramNotifier("TOK", "123", messenger=fake_messenger)
    n.send_error("boom")

    assert msgs[0][0] == "TOK" and msgs[0][1] == "123"
    assert "boom" in msgs[0][2] and "MLaud" in msgs[0][2]
