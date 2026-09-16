# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="opening fits everything by default; home is 1:1 with every window where it is"
run_scenario() {
    c open
    assert_eq "visible" "$(sget visible)" true
    assert_true "opens zoomed out (OpenZoom=fit)" "$(awk -v z="$(sget zoom)" 'BEGIN{print (z<1)}')" = 1
    assert_eq "entries" "$(sget entries)" 5
    c home
    assert_eq "zoom at home" "$(sget zoom)" 1.0000
    assert_eq "KCalc canvas x" "$(eget KCalc x)" 100
    assert_eq "KCalc frame x" "$(eget KCalc fx)" 100
    snap open-1to1
    c cancel
    assert_eq "visible after cancel" "$(sget visible)" false
}
