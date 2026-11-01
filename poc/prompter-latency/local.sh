#!/usr/bin/env bash
# S5, локальный кандидат: поднять llama-server скриптом пользователя, дождаться /health,
# прогнать 10 ходов, погасить сервер. Не запускать одновременно с S1: 28 ГБ весов без mmap.
set -u
cd "$(dirname "$0")/../.."
LOG_DIR="${LOG_DIR:-$HOME/ASR/spikes/prompter-latency/logs}"; mkdir -p "$LOG_DIR"
LAUNCH="$HOME/my_projects/local llm/templates/llama-server-launch.sh"
if curl -s http://127.0.0.1:8080/health >/dev/null 2>&1; then
  echo "llama-server уже слушает 8080 — использую его"; STARTED=0
else
  echo "=== $(date +%H:%M:%S) запуск llama-server"; STARTED=1
  bash "$LAUNCH" > "$LOG_DIR/llama-server.log" 2>&1 &
  SERVER_PID=$!
  for i in $(seq 1 180); do
    if curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"'; then break; fi
    if ! kill -0 $SERVER_PID 2>/dev/null; then echo "сервер умер, см. $LOG_DIR/llama-server.log"; exit 1; fi
    sleep 2
  done
  echo "=== $(date +%H:%M:%S) сервер готов через ~$((i*2)) с"
fi
ps -o rss= -p "$(pgrep -f llama-server | head -1)" | awk '{printf "RSS сервера: %.1f ГБ\n", $1/1048576}'
poc/prompter-latency/.venv/bin/python poc/prompter-latency/run.py openai \
  --base-url http://127.0.0.1:8080 --model local --label local-qwen3.6-35b-a3b 2>&1 | tee "$LOG_DIR/local.log"
if [ "$STARTED" = "1" ]; then echo "=== $(date +%H:%M:%S) гашу llama-server"; pkill -f llama-server; fi
