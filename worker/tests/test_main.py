"""Тесты вывода и кода возврата mlaud_worker.__main__.main().

Главное, что проверяем: провал доставки в Telegram больше не невидим —
он печатает WARN в stderr и даёт ненулевой код возврата (виден в меню приложения).
"""

import mlaud_worker.__main__ as m


def _patch(monkeypatch, result):
    monkeypatch.setattr(m, "load_dotenv", lambda: None)
    monkeypatch.setattr(m, "build_config", lambda: object())
    monkeypatch.setattr(m, "build_notifier", lambda: None)
    monkeypatch.setattr(m, "process_inbox", lambda cfg, notifier=None: result)


def test_delivery_failure_is_visible_and_nonzero(monkeypatch, capsys):
    _patch(monkeypatch, {
        "processed": [{"source": "a.m4a", "txt": "/out/a.txt",
                       "segments": 3, "delivery": "failed: 403 Forbidden"}],
        "errors": [],
    })
    code = m.main()
    out = capsys.readouterr()
    assert code == 1  # провал доставки делает прогон неуспешным
    assert "доставка: failed: 403 Forbidden" in out.out
    assert "WARN" in out.err and "доставка в Telegram не удалась" in out.err


def test_successful_delivery_is_zero(monkeypatch, capsys):
    _patch(monkeypatch, {
        "processed": [{"source": "a.m4a", "txt": "/out/a.txt",
                       "segments": 3, "delivery": "sent"}],
        "errors": [],
    })
    code = m.main()
    out = capsys.readouterr()
    assert code == 0
    assert "доставка: sent" in out.out
    assert out.err == ""


def test_transcription_error_still_nonzero(monkeypatch, capsys):
    _patch(monkeypatch, {
        "processed": [],
        "errors": [{"source": "bad.m4a", "error": "boom"}],
    })
    code = m.main()
    out = capsys.readouterr()
    assert code == 1
    assert "FAIL bad.m4a: boom" in out.err


def test_redelivered_reported(monkeypatch, capsys):
    _patch(monkeypatch, {
        "processed": [],
        "errors": [],
        "redelivered": ["старый разговор"],
        "pending": [],
    })
    code = m.main()
    out = capsys.readouterr()
    assert code == 0  # всё доставлено, очередь пуста
    assert "RESEND старый разговор" in out.out


def test_pending_queue_is_reported_but_zero(monkeypatch, capsys):
    """Ожидание сети — не ошибка прогона.

    Ненулевой код здесь заставлял приложение показать уведомление и перезапустить
    worker, а тот снова упирался в лежащую сеть — busy-loop раз в ~12 с.
    """
    _patch(monkeypatch, {
        "processed": [],
        "errors": [],
        "redelivered": [],
        "pending": ["недоставленный"],
    })
    code = m.main()
    out = capsys.readouterr()
    assert code == 0
    assert "в очереди на доставку: 1" in out.err
    assert "недоставленный" in out.err


def test_given_up_is_reported_and_nonzero(monkeypatch, capsys):
    _patch(monkeypatch, {
        "processed": [],
        "errors": [],
        "redelivered": [],
        "pending": [],
        "given_up": [{"base": "сгоревший", "txt": "/out/сгоревший.txt"}],
    })
    code = m.main()
    out = capsys.readouterr()
    assert code == 1  # исчерпали лимит попыток — это уже отказ, а не ожидание
    assert "GIVEUP сгоревший" in out.err
    assert "/out/сгоревший.txt" in out.err
