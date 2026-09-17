# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="a slide at 1:1 opens quietly, moves every window, and closes"
run_scenario() {
    c state
    local x0 y0 d0; x0=$(eget KCalc fx); y0=$(eget KCalc fy); d0=$(eget Dolphin fx)
    c "slide 500 300"
    assert_eq "opened quietly" "$(head -1 <<<"$LAST_STATE" | grep -c 'visible=true quiet')" 1
    c state
    assert_eq "closed after the slide" "$(sget visible)" false
    assert_near "KCalc moved left" "$(eget KCalc fx)" $((x0 - 500)) 1
    assert_near "KCalc moved up" "$(eget KCalc fy)" $((y0 - 300)) 1
    assert_near "Dolphin moved with it" "$(eget Dolphin fx)" $((d0 - 500)) 1
    assert_near "target follows" "$(tget 0 x)" "$(sget viewx)" 1
    # A swipe follows the fingers, then settles one step.
    c "swipe -1 0 0.5"
    assert_eq "swipe opened quietly" "$(head -1 <<<"$LAST_STATE" | grep -c 'visible=true quiet')" 1
    local vx; vx=$(sget viewx)
    c "swipe -1 0 end"
    c state
    assert_eq "closed after the swipe" "$(sget visible)" false
    assert_near "swipe left moved the camera right one step" "$(sget viewx)" $(awk -v x="$vx" 'BEGIN{print x+480}') 1
    # A cancelled swipe slides back and writes nothing.
    c "swipe 0 1 0.3"
    c "swipe 0 1 cancel"
    c state
    assert_eq "closed after the cancel" "$(sget visible)" false
    assert_near "cancel kept KCalc" "$(eget KCalc fx)" $((x0 - 500 - 960)) 1
    c "slide -1460 -300"
    c state
    assert_eq "back where it started" "$(eget KCalc fx)" "$x0"
}
