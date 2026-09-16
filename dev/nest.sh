#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
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
#   dev/nest.sh fixtures      launch the fixture set of KDE apps on fixture files
#   dev/nest.sh input CMDS    inject pointer/keyboard events (see tools/fakeinput.c)
#   dev/nest.sh clean         kill leftovers of nests whose state is gone
#   dev/nest.sh shell         start plasmashell in the nest (up does this; NEST_SHELL=0 skips)
#
# NEST_NAME=foo runs a second, independent nest (own socket, bus, config, log).
# NEST_WALLPAPER=0 keeps the plain grid instead of tiling the fixture wallpaper.
# NEST_OUTPUTS=2 gives the nest two side-by-side outputs (one frame each).
# The nest has its own activity manager with two seeded activities, so the
# frame groups and the send-to menu have something to show.
# The file is sourceable: `source dev/nest.sh` exposes every function without
# running a command, which is how tests/lib.sh reuses it.
#
# Debug commands: open commit cancel toggle home extents state
#                 pan DX DY | zoom Z [X Y] | shift DX DY
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NEST_NAME=${NEST_NAME:-kwincanvas}
STATE=${XDG_RUNTIME_DIR:-/tmp}/kwin-canvas-nest-$NEST_NAME
CONF=$STATE/config
SOCKET=wayland-$NEST_NAME
WIDTH=${NEST_WIDTH:-1920}
HEIGHT=${NEST_HEIGHT:-1080}
OUTPUTS=${NEST_OUTPUTS:-1}
LOG=$STATE/kwin.log
FIXTURES=$HERE/tests/fixtures
# Fixed ids for the two seeded activities, so tests can name them.
ACT1=11111111-1111-4111-8111-111111111111
ACT2=22222222-2222-4222-8222-222222222222

bus() { cat "$STATE/bus" 2>/dev/null; }
nq() { DBUS_SESSION_BUS_ADDRESS=$(bus) qdbus6 "$@"; }
alive() { [ -f "$STATE/pid" ] && kill -0 "$(cat "$STATE/pid")" 2>/dev/null; }

# The fixture wallpaper for a space (1-based). NEST_WALLPAPER=0 disables
# image wallpapers and leaves the Canvas Ground grid at 1:1.
wallpaper_file() {
    [ "${NEST_WALLPAPER:-1}" = 1 ] || { echo ""; return; }
    [ -f "$FIXTURES/wallpaper-${1:-1}.png" ] || python3 "$FIXTURES/gen.py" >/dev/null
    echo "file://$FIXTURES/wallpaper-${1:-1}.png"
}

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
PublishGround=true
BorderActivate=7
DebugSeq=0
ToggleShortcut=Ctrl+Alt+Space
HomeShortcut=Ctrl+Alt+Home

[Compositing]
Backend=OpenGL

[Desktops]
Number=2
Rows=1
CFG
    # The nest's activity manager reads these; the state file (XDG_STATE_HOME)
    # names the current one. Rewritten on every up, so an added activity
    # never lingers.
    cat > "$CONF/kactivitymanagerdrc" <<CFG
[activities]
$ACT1=Activity 1
$ACT2=Activity 2
CFG
    mkdir -p "$STATE/state" "$STATE/data"
    cat > "$STATE/state/kactivitymanagerdstaterc" <<CFG
[main]
currentActivity=$ACT1
CFG
}

# plasmashell inside the nest, shaped through its scripting interface after it
# starts: no panels, the Canvas Ground wallpaper, and a folder view on an
# empty directory. This is the same evaluateScript path the effect uses to
# publish the ground offset, so the handoff is exercised on every nest.
shell() {
    [ "${NEST_SHELL:-1}" = 1 ] || return 0
    mkdir -p "$STATE/desktop"
    run plasmashell --no-respawn >/dev/null
    local ok=0
    for _ in $(seq 1 60); do
        nq org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "1" >/dev/null 2>&1 && { ok=1; break; }
        sleep 0.25
    done
    [ "$ok" = 1 ] || { echo "plasmashell did not come up; see: dev/nest.sh log"; return 1; }
    local wp; wp=$(wallpaper_file 1)
    if [ -n "$wp" ]; then
        # Stock image wallpaper, one per activity in name order: the frame
        # interior is a real picture, and 1:1 is that picture. The ground
        # grid lives in the effect only.
        nq org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
            for (const p of panels()) p.remove();
            const ids = activities().slice().sort(function (a, b) { return activityName(a) < activityName(b) ? -1 : 1; });
            for (let i = 0; i < ids.length; ++i) {
                for (const d of desktopsForActivity(ids[i])) {
                    d.currentConfigGroup = ['General'];
                    d.writeConfig('url', 'file://$STATE/desktop');
                    d.wallpaperPlugin = 'org.kde.image';
                    d.currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];
                    d.writeConfig('Image', 'file://$FIXTURES/wallpaper-' + ((i % 4) + 1) + '.png');
                    d.writeConfig('FillMode', 2);
                    d.reloadConfig();
                }
            }" >/dev/null
    else
        nq org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
            for (const p of panels()) p.remove();
            for (const d of desktops()) {
                d.currentConfigGroup = ['General'];
                d.writeConfig('url', 'file://$STATE/desktop');
                d.wallpaperPlugin = 'kwin-canvas-ground';
                d.currentConfigGroup = ['Wallpaper', 'kwin-canvas-ground', 'General'];
                d.writeConfig('OffsetX', 0);
                d.writeConfig('OffsetY', 0);
                d.reloadConfig();
            }" >/dev/null
    fi
    echo "plasmashell up"
}

up() {
    if alive; then echo "already up (pid $(cat "$STATE/pid"))"; return; fi
    mkdir -p "$STATE"; rm -f "$STATE/bus" "$STATE/clients" "$STATE/pid"
    seed_config
    # setsid: the nest gets its own session so nothing that happens to the
    # shell or make that started it can reap it. The pid recorded is
    # dbus-run-session's, written from inside as its child's $PPID. The
    # environment goes on dbus-run-session itself, so the daemons the bus
    # activates (the activity manager above all) read the nest's config.
    # The data home is the nest's too, so the activity manager's database
    # is not the live session's; ~/.local/share stays on the search path
    # for the installed packages. Clients launched with run() keep the
    # user's data home, so the fixture apps look as they do at 1:1.
    (
        cd "$STATE"
        setsid -f env XDG_CONFIG_HOME="$STATE/config" XDG_STATE_HOME="$STATE/state" \
            XDG_DATA_HOME="$STATE/data" XDG_DATA_DIRS="$HOME/.local/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" \
            QT_LOGGING_TO_CONSOLE=1 KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
            dbus-run-session -- bash -c '
            echo "$PPID" > "$0/pid"
            echo "$DBUS_SESSION_BUS_ADDRESS" > "$0/bus"
            exec kwin_wayland --width '"$WIDTH"' --height '"$HEIGHT"' --output-count '"$OUTPUTS"' --xwayland --no-lockscreen --socket '"$SOCKET"'
        ' "$STATE" > "$LOG" 2>&1
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
    shell
}

# Every process attached to the nest's private bus: the compositor, the
# clients launched into it, and the daemons D-Bus activated there (portals,
# kactivitymanagerd, kglobalacceld). Those daemons outlive the bus otherwise.
pids_on_bus() {   # pids_on_bus BUS_ADDRESS
    local addr=$1 p
    for p in /proc/[0-9]*; do
        if cat "$p/environ" 2>/dev/null | tr '\0' '\n' | grep -qxF "DBUS_SESSION_BUS_ADDRESS=$addr"; then
            echo "${p#/proc/}"
        fi
    done
}

down() {
    local addr; addr=$(bus)
    if [ -f "$STATE/pid" ]; then
        pkill -P "$(cat "$STATE/pid")" 2>/dev/null || true
        kill "$(cat "$STATE/pid")" 2>/dev/null || true
    fi
    if [ -n "$addr" ]; then
        local pids; pids=$(pids_on_bus "$addr")
        [ -n "$pids" ] && kill $pids 2>/dev/null
        sleep 0.3
        pids=$(pids_on_bus "$addr")
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    fi
    rm -f "$STATE/pid" "$STATE/bus" "$STATE/clients"
    echo "down"
}

# Kill leftovers from nests whose state is gone: anything on a private bus
# that is neither the live session bus nor a running nest's bus.
clean() {
    local live=${DBUS_SESSION_BUS_ADDRESS:-} keep="" f p addr n=0
    # A bus file whose nest is gone is a leftover too.
    for f in "${XDG_RUNTIME_DIR:-/tmp}"/kwin-canvas-nest-*/bus; do
        [ -f "$f" ] || continue
        local d; d=$(dirname "$f")
        if [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then
            keep="$keep $(cat "$f")"
        else
            rm -f "$f" "$d/pid"
        fi
    done
    for p in /proc/[0-9]*; do
        # Unreadable environs (other users' processes) must not end the sweep under set -e.
        addr=$({ cat "$p/environ" 2>/dev/null || true; } | tr '\0' '\n' | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
        [ -n "$addr" ] || continue
        [ "$addr" = "$live" ] && continue
        case "$addr" in unix:path=/tmp/dbus-*|unix:abstract=/tmp/dbus-*) ;; *) continue ;; esac
        case " $keep " in *" $addr "*) continue ;; esac
        kill "${p#/proc/}" 2>/dev/null && n=$((n + 1))
    done
    # Nested compositors with no state file left.
    for p in $(pgrep -f "kwin_wayland .*--socket wayland-" ); do
        local sock; sock=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' '\n' | grep -A1 -x -- --socket | tail -1)
        [ "$sock" = "wayland-0" ] && continue
        [ -f "${XDG_RUNTIME_DIR:-/tmp}/kwin-canvas-nest-${sock#wayland-}/pid" ] && continue
        kill "$p" 2>/dev/null && n=$((n + 1))
    done
    echo "cleaned $n orphaned processes"
}

run() {
    alive || { echo "not up"; exit 1; }
    ( export WAYLAND_DISPLAY=$SOCKET DBUS_SESSION_BUS_ADDRESS=$(bus) XDG_CONFIG_HOME=$CONF XDG_STATE_HOME=$STATE/state; unset DISPLAY; "$@" >/dev/null 2>&1 & echo $! >> "$STATE/clients" )
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
    awk '/kwin-canvas state/{buf=$0; sub(/.*kwin-canvas state/, "state", buf); buf=buf "\n"; on=1; next}
         on && /^  [\[{]/{buf=buf $0 "\n"; next}
         {on=0}
         END{printf "%s", buf}' "$LOG"
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

# A typical set of KDE apps opened on fixture files, so their content is the
# same on every run. Captions: KCalc, sample.txt — KWrite, Konsole,
# fixtures — Dolphin, wallpaper.png – Gwenview.
fixtures() {
    [ -f "$FIXTURES/wallpaper.png" ] || python3 "$FIXTURES/gen.py" >/dev/null
    rm -f "$FIXTURES"/.*.kate-swp "$FIXTURES"/*.swp 2>/dev/null
    run kcalc >/dev/null
    run kwrite "$FIXTURES/sample.txt" >/dev/null
    run konsole -e sh -c "cat '$FIXTURES/konsole.txt'; exec sleep 1d" >/dev/null
    run dolphin "$FIXTURES" >/dev/null
    run gwenview "$FIXTURES/wallpaper.png" >/dev/null
    sleep 4
    echo "fixtures: kcalc kwrite konsole dolphin gwenview"
}

# Inject input through KWin's fake-input protocol. Commands on stdin, or as
# arguments for a single command: move X Y | drag X1 Y1 X2 Y2 | wheel N |
# click | key NAME | sleep MS. Built by `make tools`.
input() {
    local bin=$HERE/build/tools/fakeinput
    [ -x "$bin" ] || { echo "fakeinput not built: make tools" >&2; return 1; }
    if [ $# -gt 0 ]; then
        WAYLAND_DISPLAY=$SOCKET "$bin" "$@"
    else
        WAYLAND_DISPLAY=$SOCKET "$bin"
    fi
}

# Only dispatch when executed, so the file can be sourced for its functions.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0 2>/dev/null

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
    fixtures) fixtures ;;
    clean) clean ;;
    shell) shell ;;
    input) shift; input "$@" ;;
    bus) bus ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
esac
