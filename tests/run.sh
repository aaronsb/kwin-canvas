#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
# Run the kwin-canvas scenarios against a dedicated nested KWin.
#
#   tests/run.sh [--update-golden] [--keep] [PATTERN]
#
# --update-golden  store this run's screenshots as the golden references
# --keep           leave the test nest running afterwards
# PATTERN          only scenarios whose file name matches
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KEEP=0; PATTERN=""
for a in "$@"; do
    case $a in
        --update-golden) export UPDATE_GOLDEN=1 ;;
        --keep) KEEP=1 ;;
        *) PATTERN=$a ;;
    esac
done
# shellcheck source=lib.sh
source "$HERE/tests/lib.sh"

echo "== kwin-canvas tests (nest: $NEST_NAME, out: $OUT)"
(cd "$HERE" && make -s install >/dev/null)
down >/dev/null 2>&1 || true
up
fixtures
arrange >/dev/null
echo "   fixtures arranged: $(sget entries) windows"

for f in "$HERE"/tests/scenarios/*.sh; do
    name=$(basename "$f" .sh)
    [ -n "$PATTERN" ] && [[ "$name" != *$PATTERN* ]] && continue
    unset -f run_scenario; scenario_desc=""
    # shellcheck source=/dev/null
    source "$f"
    echo "-- $name: $scenario_desc"
    run_scenario
    c cancel >/dev/null 2>&1 || true
done

echo "== pass $PASS  fail $FAIL  skip $SKIP"
[ "$KEEP" = 1 ] || down >/dev/null
[ "$FAIL" = 0 ]
