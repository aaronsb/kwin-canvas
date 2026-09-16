#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Regenerate the screenshot tour in docs/images from a dedicated nest. The
# prose in docs/tour.md refers to these file names; rerun after any visual
# change. Images are scaled to 1280 wide for the repo.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export NEST_NAME=${NEST_NAME:-tour}
export TEST_OUT=$HERE/build/tour
# shellcheck source=../tests/lib.sh
source "$HERE/tests/lib.sh"
IMG=$HERE/docs/images
mkdir -p "$IMG"

scene() {   # scene NAME: capture the nest into docs/images/NAME.png at 1280 wide
    sleep 0.6
    shot "$OUT/$1.png" >/dev/null
    magick "$OUT/$1.png" -resize 1280x "$IMG/$1.png"
    echo "  $1"
}
trap 'down >/dev/null' EXIT

echo "== tour (nest: $NEST_NAME)"
down >/dev/null 2>&1 || true
up
fixtures
arrange >/dev/null

# 1. The desktop at 1:1: nothing running, an ordinary Plasma desktop.
scene 01-desktop

# 2. Hero: open, zoomed to fit, two activities with their frames, one window
#    living in Activity 2, one floating on the plane outside every frame.
open_1to1
c "placeby Gwenview 2500 200"
c "placeby KCalc 2300 1500"
c extents
scene 02-hero

# 3. Further out: the ground's coarser octaves and coordinate labels.
c "zoom 0.18 960 540"
scene 03-far-out

# 4. Help panel: every control, rendered from the same config the actions read.
c extents
c help
scene 04-help
c help

# 5. Resize from the canvas: KWrite commanded to a new size, live.
local_i=$(eget sample.txt index)
c "resize $local_i 1000 700"
sleep 0.6
scene 05-resize
c "resize $local_i 700 520"
sleep 0.6

# 6. A third activity, its frames placed on the plane, a window dragged into it.
c addactivity
sleep 1.2
c state
tx=$(tget 2 x); ty=$(tget 2 y)
c "placeby Dolphin $((tx + 300)) $((ty + 200))"
c extents
scene 06-three-activities

# 7. Apply, then switch to Activity 2 at 1:1: Gwenview is what that activity shows.
c commit
c "activity 1"
sleep 1.0
scene 07-activity-2

# 8. Back on Activity 1, the plane panned: the toolbar in a corner, square.
c "activity 0"
sleep 1.0
kwriteconfig6 --file "$CONF/kwinrc" --group Effect-kwin-canvas --key HudPosition BottomRight
nq org.kde.KWin /Effects org.kde.kwin.Effects.reconfigureEffect kwin-canvas
sleep 0.3
open_1to1
c "zoom 0.5 960 540"
scene 08-corner-toolbar
c cancel

echo "images in $IMG"
