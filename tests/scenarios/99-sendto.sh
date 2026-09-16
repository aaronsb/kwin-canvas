# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="send to: a desktop keeps in-frame positions; plane parks outside every frame"
run_scenario() {
    open_1to1
    local k w; k=$(eget KCalc index); w=$(eget sample.txt index)
    c "select $k"; c "selectadd $w"
    c state
    local t1; t1=$(tget 1 x)
    c "sendto 1"
    assert_eq "KCalc same place in desktop 2's frame" "$(eget KCalc x)" $((t1 + 100))
    assert_eq "KWrite same place in desktop 2's frame" "$(eget sample.txt x)" $((t1 + 640))
    c "sendto none"
    local kx ky; kx=$(eget KCalc x); ky=$(eget KCalc y)
    assert_true "parked outside desktop 1's frame" "$(awk -v x="$kx" -v y="$ky" 'BEGIN{print (x+480<=0 || y+420<=0 || x>=1920 || y>=1080)}')" = 1
    assert_eq "group geometry kept" "$(( $(eget sample.txt x) - kx ))" 540
    c commit
    assert_eq "plane windows keep their desktop" "$(eget KCalc desktop)" "$(tget 0 name)"
    arrange >/dev/null
}
