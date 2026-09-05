#!/usr/bin/env bash
# S5 через OpenRouter (ключ дан пользователем 2026-09-05): те же две модели и три варианта, что в
# flash.sh, чтобы отделить задержку шлюза от задержки модели. Стартует после RouterAI-матрицы,
# чтобы прогоны не шли параллельно.
set -u
cd "$(dirname "$0")/../.."
LOG_DIR="${LOG_DIR:-$HOME/ASR/spikes/prompter-latency/logs}"; mkdir -p "$LOG_DIR"
PY=poc/prompter-latency/.venv/bin/python
KEY="${OPENROUTER_KEY_FILE:?путь к файлу с ключом}"
BASE=https://openrouter.ai/api/v1
if [ "${WAIT_FOR_FLASH:-1}" = "1" ]; then
  until grep -q "flash done" "$LOG_DIR/progress.log" 2>/dev/null; do sleep 20; done
fi
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
  run "or-$tag-asis"     --model "$model"
  run "or-$tag-noreason" --model "$model" --reasoning-json '{"enabled": false}'
  run "or-$tag-terse"    --model "$model" --reasoning-json '{"enabled": false}' --terse
done
echo "=== $(date +%H:%M:%S) openrouter done" | tee -a "$LOG_DIR/progress.log"
