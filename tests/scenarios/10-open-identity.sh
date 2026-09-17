# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="opening is 1:1 on the current viewport by default; fit is a key away; home is 1:1 with every window where it is"
run_scenario() {
    c open
    assert_eq "visible" "$(sget visible)" true
    assert_eq "opens at 1:1 (OpenZoom=1)" "$(sget zoom)" 1.0000
    assert_near "view x is the current target" "$(sget viewx)" "$(tget 0 x)" 0.5
    assert_near "view y is the current target" "$(sget viewy)" "$(tget 0 y)" 0.5
    assert_eq "entries" "$(sget entries)" 5
    c extents
    assert_true "fit zooms out" "$(awk -v z="$(sget zoom)" 'BEGIN{print (z<1)}')" = 1
    c home
    assert_eq "zoom at home" "$(sget zoom)" 1.0000
    assert_eq "KCalc canvas x" "$(eget KCalc x)" 100
    assert_eq "KCalc frame x" "$(eget KCalc fx)" 100
    snap open-1to1
    c cancel
    assert_eq "visible after cancel" "$(sget visible)" false
}
