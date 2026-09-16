#!/usr/bin/env bash
# Test library for kwin-canvas. Sourced by tests/run.sh; scenarios are sourced
# after it and define run_scenario(). Reuses dev/nest.sh for everything that
# talks to the nested compositor.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export NEST_NAME=${NEST_NAME:-test}
# shellcheck source=../dev/nest.sh
source "$HERE/dev/nest.sh"
# nest.sh sets -e for its own use; a test runner must survive failing checks.
set +e

OUT=${TEST_OUT:-$HERE/build/test}
GOLDEN_DIR=$HERE/tests/golden
UPDATE_GOLDEN=${UPDATE_GOLDEN:-0}
TOLERANCE=${GOLDEN_TOLERANCE:-0.03}
PASS=0; FAIL=0; SKIP=0
LAST_STATE=""
mkdir -p "$OUT"

# ---- driving the effect -----------------------------------------------------
# c "command": send a debug command, keep the state it printed.
c() {
    LAST_STATE=$(cmd "$1")
}

# sget zoom|viewx|viewy|visible|desktop|entries  -> value from the last state line
sget() {
    local line; line=$(head -1 <<<"$LAST_STATE")
    case $1 in
        zoom)    sed -n 's/.*zoom=\([0-9.]*\).*/\1/p' <<<"$line" ;;
        viewx)   sed -n 's/.*view=(\([-0-9.]*\),.*/\1/p' <<<"$line" ;;
        viewy)   sed -n 's/.*view=([-0-9.]*,\([-0-9.]*\)).*/\1/p' <<<"$line" ;;
        visible) sed -n 's/.*visible=\([a-z]*\).*/\1/p' <<<"$line" ;;
        desktop) sed -n 's/.*desktop=\(.*\) entries=.*/\1/p' <<<"$line" ;;
        entries) sed -n 's/.*entries=\([0-9]*\).*/\1/p' <<<"$line" ;;
        ndesktops) grep -c '^  {' <<<"$LAST_STATE" ;;
    esac
}

# eget CAPTION_SUBSTR x|y|w|h|fx|fy|desktop|index  -> field of the matching entry
eget() {
    local line; line=$(grep -a "^  \[[0-9]*\] .*$1" <<<"$LAST_STATE" | head -1)
    [ -n "$line" ] || { echo ""; return; }
    case $2 in
        index)   sed -n 's/^  \[\([0-9]*\)\].*/\1/p' <<<"$line" ;;
        x)       sed -n 's/.*canvas=(\([-0-9.]*\),.*/\1/p' <<<"$line" ;;
        y)       sed -n 's/.*canvas=([-0-9.]*,\([-0-9.]*\) .*/\1/p' <<<"$line" ;;
        w)       sed -n 's/.*canvas=([-0-9.]*,[-0-9.]* \([0-9.]*\)x.*/\1/p' <<<"$line" ;;
        h)       sed -n 's/.*canvas=([-0-9.]*,[-0-9.]* [0-9.]*x\([0-9.]*\)).*/\1/p' <<<"$line" ;;
        fx)      sed -n 's/.*frame=(\([-0-9.]*\),.*/\1/p' <<<"$line" ;;
        fy)      sed -n 's/.*frame=([-0-9.]*,\([-0-9.]*\)).*/\1/p' <<<"$line" ;;
        desktop) sed -n 's/.*desktop=\(.*\)$/\1/p' <<<"$line" ;;
    esac
}

# tget INDEX x|y  -> a desktop target from the last state block
tget() {
    local line; line=$(grep -a "^  {$1}" <<<"$LAST_STATE" | head -1)
    case $2 in
        x) sed -n 's/.*target=(\([-0-9.]*\),.*/\1/p' <<<"$line" ;;
        y) sed -n 's/.*target=([-0-9.]*,\([-0-9.]*\)).*/\1/p' <<<"$line" ;;
        name) sed -n 's/^  {[0-9]*} \(.*\) target=.*/\1/p' <<<"$line" ;;
    esac
}

# ---- assertions -------------------------------------------------------------
ok()   { PASS=$((PASS + 1)); echo "    ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "    FAIL $1"; }
skip() { SKIP=$((SKIP + 1)); echo "    skip $1"; }

assert_eq() {   # name actual expected
    if [ "$2" = "$3" ]; then ok "$1 = $3"; else fail "$1: expected '$3', got '$2'"; fi
}
assert_near() { # name actual expected [tolerance]
    local tol=${4:-1}
    if [ -z "$2" ]; then fail "$1: no value"; return; fi
    if awk -v a="$2" -v e="$3" -v t="$tol" 'BEGIN{d=a-e; if (d<0) d=-d; exit !(d<=t)}'; then
        ok "$1 = $2 (~$3)"
    else
        fail "$1: expected ~$3 (±$tol), got $2"
    fi
}
assert_true() { # name shell-test-args...
    local name=$1; shift
    if test "$@"; then ok "$name"; else fail "$name"; fi
}

# ---- screenshots ------------------------------------------------------------
# snap NAME: screenshot the nest; with UPDATE_GOLDEN=1 store it as the golden,
# otherwise compare against the golden (RMSE, normalized) within TOLERANCE.
snap() {
    local name=$1 file=$OUT/$1.png golden=$GOLDEN_DIR/$1.png
    sleep "${SNAP_SETTLE:-0.4}"
    shot "$file" >/dev/null
    [ -s "$file" ] || { fail "snap $name: screenshot failed"; return; }
    if [ "$UPDATE_GOLDEN" = 1 ]; then
        mkdir -p "$GOLDEN_DIR"; cp "$file" "$golden"; ok "golden $name updated"; return
    fi
    [ -f "$golden" ] || { skip "snap $name: no golden (make golden)"; return; }
    local metric
    # compare exits 1 whenever the images differ at all; the number is what matters.
    metric=$( { magick compare -metric RMSE "$golden" "$file" "$OUT/$name.diff.png" 2>&1 || true; } | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
    if [ -z "$metric" ]; then fail "snap $name: compare failed"; return; fi
    if awk -v m="$metric" -v t="$TOLERANCE" 'BEGIN{exit !(m<=t)}'; then
        ok "snap $name (rmse $metric)"; rm -f "$OUT/$name.diff.png"
    else
        fail "snap $name: rmse $metric > $TOLERANCE, diff at $OUT/$name.diff.png"
    fi
}

# ---- fixture layout ---------------------------------------------------------
# A fixed arrangement of the fixture windows in canvas units. Everything
# assumes the current desktop's target is (0,0), which resetview guarantees.
declare -A LAYOUT=(
    [KCalc]="100 120 480 420"
    [sample.txt]="640 120 700 520"
    [Konsole]="100 600 620 420"
    [Dolphin]="780 680 700 360"
    [Gwenview]="1400 120 460 420"
)
arrange() {
    c cancel >/dev/null 2>&1 || true
    c resetview
    c open
    for cap in "${!LAYOUT[@]}"; do c "placeby $cap ${LAYOUT[$cap]}"; done
    sleep 0.6
    c commit
    # Deterministic screenshots: the same active window (shadow, decoration)
    # and the pointer parked where it hovers nothing.
    c "activate KCalc"
    have_input && input move 1915 1075
    sleep 0.3
}

have_input() { [ -x "$HERE/build/tools/fakeinput" ]; }
