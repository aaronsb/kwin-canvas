# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="activities are frame groups; a window in another activity's frame moves there"
run_scenario() {
    open_1to1
    c state
    assert_eq "two seeded activities" "$(sget nactivities)" 2
    assert_eq "current is Activity 1" "$(sget activity)" "Activity 1"
    c addactivity
    sleep 1.2
    c state
    assert_eq "three activities" "$(sget nactivities)" 3
    assert_eq "new one named by count" "$(tget 2 name)" "Activity 3"
    local tx ty; tx=$(tget 2 x); ty=$(tget 2 y)
    assert_true "new activity placed apart" "$tx" != "$(tget 0 x)"
    c "placeby KCalc $((tx + 200)) $((ty + 200))"
    c extents
    snap three-activities
    c commit
    assert_eq "KCalc on the new activity" "$(eget KCalc activity)" "Activity 3"
    assert_eq "KCalc frame x relative to its frame" "$(eget KCalc fx)" 200
    c "activity 2"
    sleep 0.8; c state
    assert_eq "switched to Activity 3" "$(sget activity)" "Activity 3"
    assert_near "view follows activity" "$(sget viewx)" "$tx" 0.5
    c "activity 0"
    sleep 0.8
    open_1to1
    c "placeby KCalc 100 120"
    c commit
    assert_eq "KCalc back on Activity 1" "$(eget KCalc activity)" "Activity 1"
    c "rmactivity 2"
    sleep 1.2
    c state
    assert_eq "two activities" "$(sget nactivities)" 2
}
