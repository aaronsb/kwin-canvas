#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
# Scripted demo of kwin-canvas driven by real (fake-input) pointer and keyboard
# events in a dedicated nest. Produces named screenshots and a frame sequence
# in build/demo, then assembles demo.mp4 and demo.gif with ffmpeg.
#
#   demo/demo.sh              run the session and build the video
#   demo/demo.sh --video-only assemble the video from existing frames
#
# For a real-time recording instead of captured frames, point OBS at the nest
# window (Window Capture, "kwin_wayland") while this runs with DEMO_FRAMES=0.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export NEST_NAME=${NEST_NAME:-demo}
export TEST_OUT=$HERE/build/demo
# shellcheck source=../tests/lib.sh
source "$HERE/tests/lib.sh"
FRAMES=$OUT/frames
FPS=${DEMO_FPS:-8}

video() {
    command -v ffmpeg >/dev/null || { echo "ffmpeg missing (make deps)"; return 1; }
    ls "$FRAMES"/*.png >/dev/null 2>&1 || { echo "no frames in $FRAMES"; return 1; }
    ffmpeg -y -loglevel error -framerate "$FPS" -pattern_type glob -i "$FRAMES/*.png" \
        -c:v libx264 -pix_fmt yuv420p -vf "scale=1280:-2" "$OUT/demo.mp4"
    ffmpeg -y -loglevel error -framerate "$FPS" -pattern_type glob -i "$FRAMES/*.png" \
        -vf "fps=$FPS,scale=960:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" "$OUT/demo.gif"
    echo "video: $OUT/demo.mp4  $OUT/demo.gif"
}

if [ "${1:-}" = "--video-only" ]; then video; exit $?; fi

have_input || { echo "fakeinput not built: make tools"; exit 1; }
rm -rf "$FRAMES"; mkdir -p "$FRAMES"

# Frame capture: a background loop grabbing the nest as fast as spectacle allows.
CAPTURING=0
capture_start() {
    [ "${DEMO_FRAMES:-1}" = 1 ] || return
    ( i=0; while :; do flock "$OUT/shot.lock" "$HERE/dev/nest.sh" shot "$FRAMES/$(printf '%05d' $i).png" >/dev/null; i=$((i + 1)); done ) &
    CAPTURING=$!
}
capture_stop() { [ "$CAPTURING" != 0 ] && kill "$CAPTURING" 2>/dev/null; CAPTURING=0; }
trap 'capture_stop; down >/dev/null' EXIT

# still NAME: a named screenshot for the README or docs.
still() { sleep 0.5; flock "$OUT/shot.lock" "$HERE/dev/nest.sh" shot "$OUT/$1.png" >/dev/null; echo "  still $1"; }
say() { echo "-- $1"; }

echo "== kwin-canvas demo (nest: $NEST_NAME, out: $OUT)"
down >/dev/null 2>&1 || true
up
fixtures
arrange >/dev/null
input move 960 540
capture_start

say "the desktop at 1:1"
still 01-desktop
say "open the canvas"
toggle; sleep 0.8
still 02-open
say "zoom out with the wheel"
for _ in 1 2 3 4 5; do input wheel -1; sleep 0.25; done
still 03-zoomed-out
say "pan across the ground"
printf 'glide 1700 950 40 12\ndrag 1700 950 1300 700 40 15\n' | input; sleep 0.4
say "move a window"
c state >/dev/null
kx=$(eget KCalc x); ky=$(eget KCalc y); z=$(sget zoom); vx=$(sget viewx); vy=$(sget viewy)
sx=$(awk -v x="$kx" -v v="$vx" -v z="$z" 'BEGIN{printf "%d", (x+240-v)*z}')
sy=$(awk -v y="$ky" -v v="$vy" -v z="$z" 'BEGIN{printf "%d", (y+210-v)*z}')
printf "glide $sx $sy 40 12\ndrag $sx $sy $((sx + 500)) $((sy + 120)) 40 15\n" | input; sleep 0.4
still 04-window-moved
say "add an activity and drag its frames"
c addactivity >/dev/null; sleep 1.2
c extents >/dev/null; sleep 0.4
still 05-three-activities
say "apply"
input key enter; sleep 1.0
still 06-applied
say "switch to the new activity and back"
c "activity 2" >/dev/null; sleep 1.0
c "activity 0" >/dev/null; sleep 1.0
capture_stop
c open >/dev/null; c "rmactivity 2" >/dev/null; sleep 1.0; c cancel >/dev/null
echo "frames: $(ls "$FRAMES" | wc -l) in $FRAMES"
video
