#!/usr/bin/env bash
# S5, кандидаты по решению пользователя 2026-09-05: только DeepSeek V4 Flash и GLM-5.3 Flash
# через RouterAI. Три варианта на модель: как есть; без рассуждений; коротко + без рассуждений.
# Всё в стриме: меряем первый токен и первую целую карточку, не только полный ответ.
set -u
cd "$(dirname "$0")/../.."
LOG_DIR="${LOG_DIR:-$HOME/ASR/spikes/prompter-latency/logs}"; mkdir -p "$LOG_DIR"
PY=poc/prompter-latency/.venv/bin/python
KEY="${ROUTERAI_KEY_FILE:?путь к файлу с ключом}"
BASE=https://routerai.ru/api/v1
run() {
  local label="$1"; shift
  echo "=== $(date +%H:%M:%S) $label: $*" | tee -a "$LOG_DIR/progress.log"
  $PY -u poc/prompter-latency/run.py openai --base-url "$BASE" --key-file "$KEY" --label "$label" --stream "$@" > "$LOG_DIR/$label.log" 2>&1
  rc=$?
  echo "=== $(date +%H:%M:%S) $label: exit $rc" | tee -a "$LOG_DIR/progress.log"
  [ "$rc" != "0" ] && tail -3 "$LOG_DIR/$label.log" | cut -c1-300 | tee -a "$LOG_DIR/progress.log"
}
for m in "deepseek/deepseek-v4-flash:ds" "z-ai/glm-5.3-flash:glm"; do
  model="${m%%:*}"; tag="${m##*:}"
  run "flash-$tag-asis"     --model "$model"
  run "flash-$tag-noreason" --model "$model" --reasoning-json '{"enabled": false}'
  run "flash-$tag-terse"    --model "$model" --reasoning-json '{"enabled": false}' --terse
done
echo "=== $(date +%H:%M:%S) flash done" | tee -a "$LOG_DIR/progress.log"
