# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="snapping: edges to a neighbour, grid to the canvas step, frames to windows"
run_scenario() {
    open_1to1
    local w; w=$(eget sample.txt index)
    # KCalc right edge is at 580. Put KWrite's left edge 5px off it and nudge: snaps flush.
    c "snap grid off"; c "snap edges on"
    c "placeby sample.txt 588 130"
    c "drag $w 3 0"
    assert_eq "edge snapped flush to KCalc" "$(eget sample.txt x)" 580
    # Pull well away from every edge: nothing holds it.
    c "drag $w 300 0"
    assert_eq "a new drag starts from the snapped spot" "$(eget sample.txt x)" 880
    # Grid: with edges off, left/top land on multiples of 64.
    c "snap edges off"; c "snap corners off"; c "snap grid on"
    c "placeby sample.txt 1015 500"
    c "drag $w 3 3"
    assert_eq "grid snapped x" "$(eget sample.txt x)" 1024
    assert_eq "grid snapped y" "$(eget sample.txt y)" 512
    # Frames snap too: desktop 2's group dragged near KWrite's right edge.
    c "snap grid off"; c "snap edges on"
    c "placeby sample.txt 2200 100"
    c state
    local tx; tx=$(tget 1 x)
    c "frames $(( (2900 - tx - 2) )) 0 1"
    c state
    assert_eq "frame left edge snapped to KWrite right edge" "$(tget 1 x)" 2900
    c cancel
    arrange >/dev/null
}
