#!/bin/zsh
# Прогон сценария пробы S2. «Приложение звонка» — QuickTime Player с речью (clip-a.txt,
# голос Милена), «другое приложение» — afplay с тоном 880 Гц. Проба запускается через
# `open`, как настоящее приложение, журнал — через `open --stdout`.
#
#   run.sh <tap|sck> <isolation|control|switch|rebuild> [флаги пробы…]
#
# isolation — тишина → речь → речь+тон → речь → тишина → тон один → выход QuickTime.
# control   — то же с --all (захват всего): тон обязан быть слышен, иначе тон не звучал.
# switch    — речь по кругу, пользователь переключает вывод на наушники и обратно.
# rebuild   — пересборка с новым номером и короткий захват: диалога быть не должно.
set -euo pipefail
zmodload zsh/datetime
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${APPAUDIO_OUT:-$HOME/ASR/spikes/appaudio}"
APP="$OUT/AppAudioProbe.app"
PY="${MLAUD_PY:-$HERE/../.venv/bin/python}"
MODE="$1"; SCENARIO="$2"; shift 2
EXTRA=("$@")
CLIPS="$OUT/clips"
mkdir -p "$CLIPS"
[ -f "$CLIPS/A.aiff" ] || say -v Milena -r 175 -o "$CLIPS/A.aiff" "$(cat "$HERE/clip-a.txt")"
[ -f "$CLIPS/B.wav" ] || "$PY" "$HERE/tone.py" "$CLIPS/B.wav" 880 10
A_DUR=$(afinfo "$CLIPS/A.aiff" | awk '/estimated duration/{print $3}')
STAMP=$(date +%H%M%S)
LOG="$OUT/$MODE-$SCENARIO-$STAMP.log"
DRV="$LOG.driver"
: > "$LOG"; : > "$DRV"

note() { echo "NOTE [$(date +%T)] $*" | tee -a "$DRV"; }
window() { echo "WINDOW $1 $2 $3" >> "$DRV"; }
qt() { osascript -e "tell application \"QuickTime Player\"" "$@" -e "end tell" >/dev/null; }
qt_open() {
    qt -e "open POSIX file \"$CLIPS/A.aiff\"" -e "set looping of document 1 to $1" -e "set audio volume of document 1 to 1"
}
qt_play() { qt -e "play document 1"; note "QuickTime: play"; }
qt_quit() { qt -e "close every document saving no" -e "quit"; note "QuickTime: quit"; }
tone() { afplay "$CLIPS/B.wav" & note "afplay: тон 10 с (pid $!)"; }
notify() { osascript -e "display notification \"$1\" with title \"Проба S2\""; note "уведомление: $1"; }
wait_until() {  # секунд от READY
    local target=$(( T0 + $1 ))
    local now=$EPOCHREALTIME
    (( now < target )) && sleep $(( target - now ))
    return 0
}

case "$SCENARIO" in
    isolation|control) TOTAL=62; LOOP=false ;;
    switch) TOTAL=45; LOOP=true ;;
    rebuild) TOTAL=10; LOOP=true; "$HERE/build.sh" "${REBUILD_NUMBER:-$(date +%H%M%S)}" ;;
    *) echo "неизвестный сценарий $SCENARIO" >&2; exit 64 ;;
esac
[ "$SCENARIO" = control ] && EXTRA+=(--all)

note "сценарий $SCENARIO, режим $MODE, речь ${A_DUR}s, флаги: ${EXTRA[*]:-—}"
qt_open "$LOOP"
LAUNCH=$EPOCHREALTIME
open --stdout "$LOG" --stderr "$LOG.err" -a "$APP" --args "$MODE" --app "QuickTime Player" --seconds "$TOTAL" --out "$OUT" "${EXTRA[@]}"
note "проба запущена, жду READY (диалог разрешения — до 180 с)"
for i in {1..900}; do
    if grep -q "READY" "$LOG"; then break; fi
    if grep -q "ERROR" "$LOG"; then cat "$LOG"; cat "$LOG.err"; exit 1; fi
    sleep 0.2
done
grep -q "READY" "$LOG" || { note "READY не дождался"; cat "$LOG" "$LOG.err"; exit 1; }
T0=$EPOCHREALTIME
note "READY через $(( T0 - LAUNCH )) с после запуска"

case "$SCENARIO" in
    isolation|control)
        window silence 1 4
        wait_until 5;  qt_play
        window speech 6 14
        wait_until 15; tone
        window speech_plus_tone 16 24
        window speech2 26 $(( 5 + A_DUR - 1 ))
        window silence2 $(( 5 + A_DUR + 2 )) 41
        wait_until 42; tone
        window tone_alone 43 51
        wait_until 55; qt_quit
        window after_quit 57 61
        ;;
    switch)
        wait_until 3; qt_play
        window before 4 8
        wait_until 8; notify "Переключите вывод на наушники"
        echo ">>> ПЕРЕКЛЮЧИТЕ вывод на наушники (AirPods) сейчас; через 20 с — обратно"
        wait_until 28; notify "Верните вывод на динамики"
        echo ">>> ВЕРНИТЕ вывод на динамики"
        window during 10 27
        window after 30 44
        wait_until 44; qt_quit
        ;;
    rebuild)
        wait_until 2; qt_play
        window speech 3 9
        wait_until 10; qt_quit
        ;;
esac
wait_until $(( TOTAL + 2 ))
for i in {1..50}; do grep -q "DONE" "$LOG" && break; sleep 0.2; done
note "конец"
echo "=== журнал: $LOG"
"$PY" "$HERE/summarize.py" "$LOG" "$DRV"
[ -s "$LOG.err" ] && { echo "=== stderr:"; cat "$LOG.err"; }
exit 0
