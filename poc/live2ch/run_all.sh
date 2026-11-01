#!/usr/bin/env bash
# Все варианты S1 подряд; логи — в каталог из $LOG_DIR. Порядок: сначала базовый
# (в него мы верим меньше всего), потом адаптивный каденс, окно 12 с, один канал.
set -u
cd "$(dirname "$0")/../.."
PY=worker/.venv/bin/python
LOG_DIR="${LOG_DIR:-$HOME/ASR/spikes/live2ch/logs}"
mkdir -p "$LOG_DIR"
run() {
  local name="$1"; shift
  echo "=== $(date +%H:%M:%S) $name: $*" | tee -a "$LOG_DIR/progress.log"
  PYTHONPATH=worker $PY poc/live2ch/run.py run --name "$name" "$@" > "$LOG_DIR/$name.log" 2>&1
  echo "=== $(date +%H:%M:%S) $name: exit $?" | tee -a "$LOG_DIR/progress.log"
}
run base     --cadence fixed    --window 18 --minutes 5
run adaptive --cadence adaptive --window 18 --minutes 5
run win12    --cadence fixed    --window 12 --minutes 5
run single   --cadence fixed    --window 18 --minutes 5 --channels them
echo "=== $(date +%H:%M:%S) all done" | tee -a "$LOG_DIR/progress.log"
