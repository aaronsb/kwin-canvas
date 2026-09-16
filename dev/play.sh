#!/usr/bin/env bash
# A nest to play in: fixture apps in the test layout, canvas open and fitted.
#   dev/play.sh            default nest (NEST_NAME=kwincanvas)
#   dev/play.sh --closed   leave the canvas closed at 1:1
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export NEST_NAME=${NEST_NAME:-kwincanvas}
export TEST_OUT=${TEST_OUT:-$HERE/build/play}
# shellcheck source=../tests/lib.sh
source "$HERE/tests/lib.sh"

up
fixtures
arrange >/dev/null
echo "arranged: $(sget entries) windows"
if [ "${1:-}" != "--closed" ]; then
    c open >/dev/null
    c extents >/dev/null
    echo "canvas open and fitted"
fi
echo
echo "Inside the nest:  Ctrl+Alt+Space opens/applies, Esc cancels, wheel zooms, drag pans"
echo "From here:        make nest-cmd CMD=\"...\"   make nest-shot   make nest-down"
