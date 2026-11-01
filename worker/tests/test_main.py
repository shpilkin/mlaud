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


def test_speakers_pending_in_ok_line(monkeypatch, capsys):
    _patch(monkeypatch, {
        "processed": [{"source": "a.m4a", "txt": "/out/a.txt", "segments": 3,
                       "delivery": "sent", "speakers": {"status": "written", "pending": 2}},
                      {"source": "b.m4a", "txt": "/out/b.txt", "segments": 1,
                       "delivery": "sent", "speakers": {"status": "failed: boom", "pending": 0}}],
        "errors": [],
    })
    assert m.main() == 0
    out = capsys.readouterr().out
    assert "[к разметке: 2]" in out and "[сайдкар голосов: failed: boom]" in out


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


def test_identify_error_is_warned_but_zero(monkeypatch, capsys):
    _patch(monkeypatch, {
        "processed": [{"source": "a.m4a", "txt": "/out/a.txt",
                       "segments": 3, "delivery": "sent"}],
        "errors": [],
        "identify_error": "Expecting value: line 1 column 2",
    })
    code = m.main()
    out = capsys.readouterr()
    assert code == 0                       # транскрипт сделан и доставлен — это не провал
    assert "база голосов не прочитана" in out.err


def test_build_config_identify_env(monkeypatch):
    for k in ("MLAUD_IDENTIFY", "MLAUD_VOICES_DIR", "MLAUD_IDENTIFY_THRESHOLD",
              "MLAUD_IDENTIFY_MIN_SPEECH"):
        monkeypatch.delenv(k, raising=False)
    cfg = m.build_config()
    assert cfg.identify is False
    assert cfg.voices_dir.name == "voices" and "Mobile Documents" not in str(cfg.voices_dir)
    assert cfg.identify_threshold == 0.75 and cfg.identify_min_speech == 30.0

    monkeypatch.setenv("MLAUD_IDENTIFY", "yes")
    monkeypatch.setenv("MLAUD_VOICES_DIR", "/tmp/v")
    monkeypatch.setenv("MLAUD_IDENTIFY_THRESHOLD", "0.8")
    monkeypatch.setenv("MLAUD_IDENTIFY_MIN_SPEECH", "abc")     # мусор → значение по умолчанию
    cfg = m.build_config()
    assert cfg.identify is True
    assert str(cfg.voices_dir) == "/tmp/v"
    assert cfg.identify_threshold == 0.8 and cfg.identify_min_speech == 30.0

    monkeypatch.setenv("MLAUD_IDENTIFY", "0")
    assert m.build_config().identify is False


def test_read_dotenv_first_nonempty_wins(tmp_path):
    from mlaud_worker.config import read_dotenv

    env = tmp_path / ".env"
    env.write_text('# комментарий\nA=\nA="1"\nA=2\nB = \'x\'\nмусор\n', encoding="utf-8")
    assert read_dotenv(env) == {"A": "1", "B": "x"}
    assert read_dotenv(tmp_path / "нет") == {}


def test_load_dotenv_does_not_override_env(monkeypatch):
    env = {"MLAUD_X1": "env"}
    monkeypatch.setattr(m.os, "environ", env)
    monkeypatch.setattr(m, "read_dotenv", lambda: {"MLAUD_X1": "file", "MLAUD_X2": "file"})
    m.load_dotenv()
    assert env == {"MLAUD_X1": "env", "MLAUD_X2": "file"}
