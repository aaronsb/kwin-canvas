# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="arrange the selection: horizontal, vertical, grid, cascade"
run_scenario() {
    open_1to1
    local k w d; k=$(eget KCalc index); w=$(eget sample.txt index); d=$(eget Dolphin index)
    c "select $k"; c "selectadd $w"; c "selectadd $d"
    # KCalc (100,120 480x420), KWrite (640,120 700x520), Dolphin (780,680 700x360); bbox from (100,120)
    c "arrange horizontal"
    assert_eq "horizontal: KCalc first" "$(eget KCalc x)" 100
    assert_eq "horizontal: KWrite after KCalc plus gap" "$(eget sample.txt x)" 596
    assert_eq "horizontal: Dolphin after KWrite plus gap" "$(eget Dolphin x)" 1312
    assert_eq "horizontal: same top" "$(eget Dolphin y)" 120
    c "arrange vertical"
    assert_eq "vertical: same left" "$(eget Dolphin x)" 100
    assert_eq "vertical: stacked" "$(eget sample.txt y)" 556
    c "arrange cascade"
    assert_eq "cascade: third is offset 80" "$(eget Dolphin x)" 180
    assert_eq "cascade: third y" "$(eget Dolphin y)" 200
    c "arrange grid 1 3"
    sleep 0.7; c state
    assert_eq "grid 1x3: three columns, second starts after first cell" "$(eget sample.txt y)" 120
    assert_true "grid 1x3: KWrite width shrank" "$(eget sample.txt w)" -lt 700
    assert_true "grid 1x3: Dolphin right of KWrite" "$(eget Dolphin x)" -gt "$(eget sample.txt x)"
    c cancel
    # sizes changed for real; put the layout back
    arrange >/dev/null
}
