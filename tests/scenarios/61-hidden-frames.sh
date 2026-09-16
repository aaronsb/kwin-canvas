# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="a hidden frame is not drawn, takes no windows, and is remembered in HiddenFrames"
run_scenario() {
    open_1to1
    c state
    local tx; tx=$(tget 1 x)
    c "hide 1"
    assert_true "state lists the hidden output" -n "$(tget 1 hidden)"
    assert_eq "HiddenFrames written to kwinrc" "$(kreadconfig6 --file "$CONF/kwinrc" --group Effect-kwin-canvas --key HiddenFrames)" "$ACT2|$(tget 1 hidden)"
    # KCalc dropped where Activity 2's frame would be stays on Activity 1.
    c "placeby KCalc $((tx + 200)) 200"
    c extents
    snap hidden-frame
    c commit
    assert_eq "KCalc stays on Activity 1" "$(eget KCalc activity)" "Activity 1"
    assert_eq "geometry relative to Activity 1" "$(eget KCalc fx)" $((tx + 200))
    open_1to1
    c "show 1"
    assert_eq "shown again" "$(tget 1 hidden)" ""
    assert_eq "HiddenFrames cleared" "$(kreadconfig6 --file "$CONF/kwinrc" --group Effect-kwin-canvas --key HiddenFrames)" ""
    c "placeby KCalc 100 120"
    c commit
}
