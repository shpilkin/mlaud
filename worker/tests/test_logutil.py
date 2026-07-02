"""Маскировка токенов в текстах ошибок (чтобы не текли в worker.log)."""

from mlaud_worker.logutil import redact


def test_redacts_telegram_token_in_url():
    # вымышленный токен той же формы, что даёт Telegram (digits:base64ish)
    fake = "1234567890:AAFake_Token-ExampleValue0123456789"
    err = ("HTTPSConnectionPool(host='api.telegram.org', port=443): "
           f"Max retries exceeded with url: /bot{fake}/sendDocument")
    out = redact(err)
    assert fake not in out
    assert "bot<redacted>/sendDocument" in out


def test_redacts_hf_token():
    fake = "hf_FakeExampleTokenValue0123456789"  # вымышленный HF-токен
    out = redact(f"auth failed with {fake} here")
    assert fake not in out
    assert "hf_<redacted>" in out


def test_leaves_plain_text_untouched():
    assert redact("обычная ошибка без секретов") == "обычная ошибка без секретов"
