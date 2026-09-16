# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="mouse gestures: double-click focuses a window, double-click a frame goes there, shift+double-click makes an activity over a window"
screen_of() {
    awk -v cx="$1" -v cy="$2" -v vx="$(sget viewx)" -v vy="$(sget viewy)" -v z="$(sget zoom)" \
        'BEGIN{printf "%d %d", (cx-vx)*z, (cy-vy)*z}'
}
dblclick() { printf "move $1 $2\nclick\nsleep 60\nclick\n" | input; }
run_scenario() {
    if ! have_input; then skip "fakeinput not built (make tools)"; return; fi
    # A window far outside every frame, then double-click it: the current
    # activity's frame comes to it and the window is focused at 1:1.
    open_1to1
    c "placeby KCalc 6000 4000"
    c extents
    read -r sx sy <<<"$(screen_of 6240 4210)"
    dblclick "$sx" "$sy"
    sleep 0.6; c state
    assert_eq "double-click applied" "$(sget visible)" false
    local fx; fx=$(eget KCalc fx)
    assert_true "KCalc on screen after focus" "$(awk -v x="$fx" 'BEGIN{print (x>=0 && x+480<=1920)}')" = 1
    assert_eq "still on Activity 1" "$(eget KCalc activity)" "Activity 1"

    # Shift+double-click on a window outside every frame: a new activity centred on it.
    open_1to1
    c "placeby Gwenview 9000 -3000"
    c extents
    read -r sx sy <<<"$(screen_of 9230 -2790)"
    printf "move $sx $sy\nkey shift down\nclick\nsleep 60\nclick\nkey shift up\n" | input
    sleep 1.5; c state
    assert_eq "three activities now" "$(sget nactivities)" 3
    assert_eq "Gwenview moved to the new activity" "$(eget Gwenview activity)" "Activity 3"
    assert_eq "new activity is current" "$(sget activity)" "Activity 3"

    # Double-click Activity 1's frame area: apply with that activity current.
    open_1to1
    c extents
    local tx ty; tx=$(tget 0 x); ty=$(tget 0 y)
    read -r sx sy <<<"$(screen_of $((tx + 1900)) $((ty + 1060)))"
    dblclick "$sx" "$sy"
    sleep 1.0; c state
    assert_eq "frame double-click applied" "$(sget visible)" false
    assert_eq "Activity 1 is current" "$(sget activity)" "Activity 1"
    # Ctrl+double-click: the camera zooms to that activity, canvas stays open.
    open_1to1
    c extents
    read -r sx sy <<<"$(screen_of $((tx + 1900)) $((ty + 1060)))"
    printf "move $sx $sy\nkey ctrl down\nclick\nsleep 60\nclick\nkey ctrl up\n" | input
    sleep 0.6; c state
    assert_eq "ctrl double-click keeps the canvas open" "$(sget visible)" true
    assert_near "camera fitted to the frame" "$(sget zoom)" 0.8889 0.01
    c cancel

    # Restore: Gwenview back, extra activity gone.
    open_1to1
    c "placeby Gwenview 1400 120"
    c commit
    c "rmactivity 2"
    sleep 1.2
    arrange >/dev/null
}
