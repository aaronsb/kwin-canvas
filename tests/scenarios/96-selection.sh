# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="selection: click, ctrl+click toggle, shift+drag marquee, group drag keeps relative geometry"
screen_of() {
    awk -v cx="$1" -v cy="$2" -v vx="$(sget viewx)" -v vy="$(sget viewy)" -v z="$(sget zoom)" \
        'BEGIN{printf "%d %d", (cx-vx)*z, (cy-vy)*z}'
}
selected() { grep -c "^  \[[0-9]*\] \*" <<<"$LAST_STATE"; }
run_scenario() {
    open_1to1
    c "zoom 0.5 960 540"
    # Two windows selected through the channel, one dragged: both move by the same delta.
    local k w; k=$(eget KCalc index); w=$(eget sample.txt index)
    c "select $k"; c "selectadd $w"
    c state
    assert_eq "two selected" "$(selected)" 2
    c "drag $k 100 50"
    assert_eq "KCalc moved x" "$(eget KCalc x)" 300
    assert_eq "KWrite moved with it x" "$(eget sample.txt x)" 840
    assert_eq "KWrite moved with it y" "$(eget sample.txt y)" 220
    assert_eq "Dolphin stayed" "$(eget Dolphin x)" 780
    c clearsel
    c state
    assert_eq "cleared" "$(selected)" 0
    if ! have_input; then skip "fakeinput not built (make tools)"; c cancel; return; fi
    # Ctrl+click toggles a window in and out.
    read -r sx sy <<<"$(screen_of $(( $(eget Dolphin x) + 350 )) $(( $(eget Dolphin y) + 180 )))"
    printf "move $sx $sy\nkey ctrl down\nclick\nkey ctrl up\n" | input
    sleep 0.4; c state
    assert_eq "ctrl+click selected Dolphin" "$(selected)" 1
    printf "move $sx $sy\nkey ctrl down\nclick\nkey ctrl up\n" | input
    sleep 0.4; c state
    assert_eq "ctrl+click again deselected" "$(selected)" 0
    # Shift+drag on the ground from beyond the layout's corner across KCalc and Konsole.
    read -r ax ay <<<"$(screen_of -200 -100)"
    read -r bx by <<<"$(screen_of 700 1100)"
    printf "key shift down\ndrag $ax $ay $bx $by 20 10\nkey shift up\n" | input
    sleep 0.5; c state
    assert_true "marquee selected two or more" "$(selected)" -ge 2
    assert_eq "Gwenview not in the marquee" "$(grep -c '^  \[[0-9]*\] \*.*Gwenview' <<<"$LAST_STATE")" 0
    c cancel
}
