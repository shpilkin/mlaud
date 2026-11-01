#!/usr/bin/env bash
# S5 через RouterAI (ключ дан пользователем 2026-09-05, лежит в сессионном каталоге, 0600).
# Кандидаты: DeepSeek V4 Flash (подключение Niti), claude-sonnet-5 и claude-opus-5 через тот же шлюз.
set -u
cd "$(dirname "$0")/../.."
LOG_DIR="${LOG_DIR:-$HOME/ASR/spikes/prompter-latency/logs}"; mkdir -p "$LOG_DIR"
PY=poc/prompter-latency/.venv/bin/python
KEY="${ROUTERAI_KEY_FILE:?путь к файлу с ключом}"
BASE=https://routerai.ru/api/v1
run() {
  local label="$1"; shift
  echo "=== $(date +%H:%M:%S) $label: $*" | tee -a "$LOG_DIR/progress.log"
  $PY poc/prompter-latency/run.py openai --base-url "$BASE" --key-file "$KEY" --label "$label" "$@" > "$LOG_DIR/$label.log" 2>&1
  rc=$?
  echo "=== $(date +%H:%M:%S) $label: exit $rc" | tee -a "$LOG_DIR/progress.log"
  [ "$rc" != "0" ] && tail -3 "$LOG_DIR/$label.log" | cut -c1-300 | tee -a "$LOG_DIR/progress.log"
}
run routerai-deepseek-v4-flash --model deepseek/deepseek-v4-flash
run routerai-claude-sonnet-5   --model anthropic/claude-sonnet-5 --cache-control
run routerai-claude-opus-5     --model anthropic/claude-opus-5   --cache-control
echo "=== $(date +%H:%M:%S) routerai done" | tee -a "$LOG_DIR/progress.log"
