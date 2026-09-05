#!/usr/bin/env bash
# S5, облачные кандидаты — подключения Niti (разрешение пользователя 2026-09-05).
# Ключи не пишутся на диск: run.py расшифровывает их кодом Niti в памяти.
# Запускать из каталога Niti с его же окружением: uv run --no-project --env-file .env -- <этот скрипт>
# (ключ шифрования Niti приходит из его .env, как при запуске самого Niti).
set -u
cd "$(dirname "$0")/../.."
LOG_DIR="${LOG_DIR:-$HOME/ASR/spikes/prompter-latency/logs}"; mkdir -p "$LOG_DIR"
PY=poc/prompter-latency/.venv/bin/python
run() {
  local label="$1" conn="$2"
  echo "=== $(date +%H:%M:%S) $label ($conn)" | tee -a "$LOG_DIR/progress.log"
  $PY poc/prompter-latency/run.py openai --niti-connection "$conn" --label "$label" > "$LOG_DIR/$label.log" 2>&1
  rc=$?
  echo "=== $(date +%H:%M:%S) $label: exit $rc" | tee -a "$LOG_DIR/progress.log"
  [ "$rc" != "0" ] && tail -3 "$LOG_DIR/$label.log" | tee -a "$LOG_DIR/progress.log"
}
run openrouter-deepseek-v4-flash "OpenRouter"
run routerai-deepseek-v4-flash   "RouterAI"
run corp-litellm-deepseek-v4-pro "Corp LiteLLM"
echo "=== $(date +%H:%M:%S) cloud done" | tee -a "$LOG_DIR/progress.log"
