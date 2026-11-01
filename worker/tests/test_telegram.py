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


def test_main_test_sends_message(monkeypatch, capsys):
    from mlaud_worker import telegram

    monkeypatch.setenv("MLAUD_TG_TOKEN", "t")
    monkeypatch.setenv("MLAUD_TG_CHAT_ID", "42")
    sent = []
    rc = telegram.main(["--test"], messenger=lambda token, chat, text: sent.append((token, chat, text)) or {})
    assert rc == 0
    assert sent == [("t", "42", f"MLaud: {telegram.TEST_TEXT}")]
    assert "отправлено" in capsys.readouterr().out


def test_main_test_without_credentials(monkeypatch, capsys):
    from mlaud_worker import telegram

    monkeypatch.delenv("MLAUD_TG_TOKEN", raising=False)
    monkeypatch.delenv("MLAUD_TG_CHAT_ID", raising=False)
    sent = []
    assert telegram.main(["--test"], messenger=lambda *a: sent.append(a)) == 2
    assert sent == []
    assert "не заданы" in capsys.readouterr().err


def test_main_test_reports_failure(monkeypatch, capsys):
    from mlaud_worker import telegram

    monkeypatch.setenv("MLAUD_TG_TOKEN", "t")
    monkeypatch.setenv("MLAUD_TG_CHAT_ID", "42")

    def boom(*a):
        raise RuntimeError("401 Unauthorized")

    assert telegram.main(["--test"], messenger=boom) == 1
    assert "401" in capsys.readouterr().err


def test_send_subcommand_sends_document(monkeypatch, tmp_path, capsys):
    """`telegram send <path>` — итоги звонка руками (4.7): ок → «отправлено: <имя>», 0."""
    from mlaud_worker import telegram

    monkeypatch.setenv("MLAUD_TG_TOKEN", "t")
    monkeypatch.setenv("MLAUD_TG_CHAT_ID", "42")
    doc = tmp_path / "2026-09-04_15-30-05.prompter.md"
    doc.write_text("# итоги", encoding="utf-8")
    sent = []
    rc = telegram.main(["send", str(doc), "--caption", "итоги"], sender=lambda token, chat, path, caption:
                       sent.append((token, chat, path, caption)) or {})
    assert rc == 0
    assert sent == [("t", "42", str(doc), "итоги")]
    assert "отправлено: 2026-09-04_15-30-05.prompter.md" in capsys.readouterr().out


def test_send_subcommand_missing_file(monkeypatch, tmp_path, capsys):
    from mlaud_worker import telegram

    monkeypatch.setenv("MLAUD_TG_TOKEN", "t")
    monkeypatch.setenv("MLAUD_TG_CHAT_ID", "42")
    sent = []
    assert telegram.main(["send", str(tmp_path / "нет.md")],
                         sender=lambda *a: sent.append(a)) == 1
    assert sent == []
    assert "нет файла" in capsys.readouterr().err


def test_send_subcommand_without_credentials(monkeypatch, tmp_path):
    from mlaud_worker import telegram

    monkeypatch.delenv("MLAUD_TG_TOKEN", raising=False)
    monkeypatch.delenv("MLAUD_TG_CHAT_ID", raising=False)
    doc = tmp_path / "итоги.md"
    doc.write_text("x", encoding="utf-8")
    assert telegram.main(["send", str(doc)]) == 2
