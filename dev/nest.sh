#!/usr/bin/env bash
# Nested KWin harness for kwin-canvas.
#
# Runs a second kwin_wayland as a window inside the live session, on its own
# D-Bus session bus and with its own XDG_CONFIG_HOME, so the effect can be
# enabled, driven and screenshotted without touching the real desktop.
#
#   dev/nest.sh up            start nested KWin with the effect enabled
#   dev/nest.sh down          stop it
#   dev/nest.sh run CMD...    launch a client into the nested session
#   dev/nest.sh cmd "pan 100 0"   send a debug command to the effect
#   dev/nest.sh toggle        press Meta+Space inside the nested session
#   dev/nest.sh shot [file]   screenshot the nested session
#   dev/nest.sh log           tail the nested KWin log
#   dev/nest.sh state         print effect state from the log
#   dev/nest.sh reload        reinstall, restart the nest, relaunch clients
#   dev/nest.sh clients       launch the default test clients (NEST_CLIENTS)
#
# Debug commands: open commit cancel toggle home extents state
#                 pan DX DY | zoom Z [X Y] | shift DX DY
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
STATE=${XDG_RUNTIME_DIR:-/tmp}/kwin-canvas-nest
CONF=$STATE/config
SOCKET=wayland-kwincanvas
WIDTH=${NEST_WIDTH:-1920}
HEIGHT=${NEST_HEIGHT:-1080}
LOG=$STATE/kwin.log

bus() { cat "$STATE/bus" 2>/dev/null; }
nq() { DBUS_SESSION_BUS_ADDRESS=$(bus) qdbus6 "$@"; }
alive() { [ -f "$STATE/pid" ] && kill -0 "$(cat "$STATE/pid")" 2>/dev/null; }

seed_config() {
    mkdir -p "$CONF"
    cat > "$CONF/kwinrc" <<CFG
[Plugins]
kwin-canvasEnabled=true
zoomEnabled=false
overviewEnabled=false
blurEnabled=false
contrastEnabled=false

[Effect-kwin-canvas]
PublishGround=false
DebugSeq=0
ToggleShortcut=Ctrl+Alt+Space
HomeShortcut=Ctrl+Alt+Home

[Compositing]
Backend=OpenGL
CFG
}

up() {
    if alive; then echo "already up (pid $(cat "$STATE/pid"))"; return; fi
    mkdir -p "$STATE"; rm -f "$STATE/bus"
    seed_config
    (
        cd "$STATE"
        dbus-run-session -- bash -c '
            echo "$DBUS_SESSION_BUS_ADDRESS" > "$0/bus"
            exec env XDG_CONFIG_HOME="$0/config" QT_LOGGING_TO_CONSOLE=1 \
                kwin_wayland --width '"$WIDTH"' --height '"$HEIGHT"' --xwayland --no-lockscreen --no-kactivities --socket '"$SOCKET"'
        ' "$STATE" > "$LOG" 2>&1 &
        echo $! > "$STATE/pid"
    )
    for _ in $(seq 1 50); do
        [ -f "$STATE/bus" ] && nq org.kde.KWin /KWin org.kde.KWin.supportInformation >/dev/null 2>&1 && break
        sleep 0.2
    done
    if nq org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded kwin-canvas 2>/dev/null | grep -q true; then
        echo "nested KWin up, effect loaded (socket $SOCKET)"
    else
        echo "nested KWin up but effect NOT loaded; see: dev/nest.sh log"
    fi
}

down() {
    if [ -f "$STATE/pid" ]; then
        pkill -P "$(cat "$STATE/pid")" 2>/dev/null || true
        kill "$(cat "$STATE/pid")" 2>/dev/null || true
        rm -f "$STATE/pid" "$STATE/bus"
        echo "down"
    fi
}

run() {
    alive || { echo "not up"; exit 1; }
    ( export WAYLAND_DISPLAY=$SOCKET DBUS_SESSION_BUS_ADDRESS=$(bus) XDG_CONFIG_HOME=$CONF; unset DISPLAY; "$@" >/dev/null 2>&1 & )
    echo "launched: $*"
}

cmd() {
    alive || { echo "not up"; exit 1; }
    local seq
    seq=$(kreadconfig6 --file "$CONF/kwinrc" --group Effect-kwin-canvas --key DebugSeq --default 0)
    seq=$((seq + 1))
    kwriteconfig6 --file "$CONF/kwinrc" --group Effect-kwin-canvas --key DebugCommand "$1"
    kwriteconfig6 --file "$CONF/kwinrc" --group Effect-kwin-canvas --key DebugSeq "$seq"
    nq org.kde.KWin /Effects org.kde.kwin.Effects.reconfigureEffect kwin-canvas
    sleep 0.3
    state
}

toggle() {
    nq org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut "Toggle Canvas"
}

shot() {
    alive || { echo "not up"; exit 1; }
    local out=${1:-$STATE/shot-$(date +%H%M%S).png}
    DBUS_SESSION_BUS_ADDRESS=$(bus) WAYLAND_DISPLAY=$SOCKET XDG_CONFIG_HOME=$CONF \
        spectacle -b -n -f -o "$out" >/dev/null 2>&1 || true
    [ -s "$out" ] && echo "$out" || echo "screenshot failed"
}

state() {
    grep -a "kwin-canvas state" "$LOG" | tail -1 | sed 's/.*kwin-canvas state/state/'
    awk "/kwin-canvas state/{buf=\"\"; on=1; next} on && /^  \\[/{buf=buf \$0 \"\\n\"; next} {on=0} END{printf \"%s\", buf}" "$LOG"
    grep -a -A30 "kwin-canvas windows:" "$LOG" | tail -n +2 | grep -a "^  [* ] " | tail -20 || true
}

log() { tail -n "${1:-60}" "$LOG"; }

# KWin's QML engine caches components by URL, so a changed main.qml never
# reloads in place. Restart the nested compositor and relaunch the clients.
reload() {
    (cd "$HERE" && make -s install >/dev/null)
    down >/dev/null
    up
    clients
}

clients() {
    for c in ${NEST_CLIENTS:-kcalc konsole kwrite}; do run "$c" >/dev/null; done
    sleep 3
    echo "clients: ${NEST_CLIENTS:-kcalc konsole kwrite}"
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    run) shift; run "$@" ;;
    cmd) cmd "$2" ;;
    toggle) toggle ;;
    shot) shot "${2:-}" ;;
    log) log "${2:-60}" ;;
    state) state ;;
    reload) reload ;;
    clients) clients ;;
    bus) bus ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
esac
