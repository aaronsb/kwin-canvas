scenario_desc="real pointer and keyboard input through fake-input: wheel, pan, drag, escape"
# Screen position of a canvas point at the current camera, from the last state.
screen_of() {   # screen_of CX CY -> "SX SY"
    awk -v cx="$1" -v cy="$2" -v vx="$(sget viewx)" -v vy="$(sget viewy)" -v z="$(sget zoom)" \
        'BEGIN{printf "%d %d", (cx-vx)*z, (cy-vy)*z}'
}
run_scenario() {
    if ! have_input; then skip "fakeinput not built (make tools)"; return; fi
    open_1to1
    c home
    c "zoom 0.4 960 540"
    input move 1700 900
    input wheel -1
    sleep 0.3; c state
    assert_near "wheel zooms out one notch" "$(sget zoom)" 0.3478 0.002
    c home
    c "zoom 0.4 960 540"
    printf 'drag 1700 900 1500 800\n' | input
    sleep 0.3; c state
    assert_near "ground drag pans x" "$(sget viewx)" -940 2
    assert_near "ground drag pans y" "$(sget viewy)" -560 2
    # Drag KCalc by its centre, 100 by 50 screen px: 250 by 125 canvas units at zoom 0.4.
    read -r sx sy <<<"$(screen_of $(( $(eget KCalc x) + 240 )) $(( $(eget KCalc y) + 210 )))"
    printf "drag $sx $sy $((sx + 100)) $((sy + 50))\n" | input
    sleep 0.3; c state
    assert_near "window drag moves x" "$(eget KCalc x)" 350 3
    assert_near "window drag moves y" "$(eget KCalc y)" 245 3
    snap input-dragged
    input key esc
    sleep 0.3; c state
    assert_eq "escape cancels" "$(sget visible)" false
    assert_eq "cancel left geometry alone" "$(eget KCalc fx)" 100
}
