# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="pan mode: hold the chord, drag the desktop, release to settle; escape slides back"
run_scenario() {
    c state
    local x0 y0; x0=$(eget KCalc fx); y0=$(eget KCalc fy)
    c panmode
    assert_eq "opened in pan mode" "$(head -1 <<<"$LAST_STATE" | grep -c 'visible=true panmode')" 1
    c "pan -300 -200"
    c "pan -100 0"
    assert_eq "still in pan mode after two drags" "$(head -1 <<<"$LAST_STATE" | grep -c panmode)" 1
    c "panmode end"
    c state
    assert_eq "closed on release" "$(sget visible)" false
    assert_near "KCalc pulled left" "$(eget KCalc fx)" $((x0 - 400)) 1
    assert_near "KCalc pulled up" "$(eget KCalc fy)" $((y0 - 200)) 1
    c panmode
    c "pan 250 0"
    c "panmode cancel"
    c state
    assert_eq "closed on cancel" "$(sget visible)" false
    assert_eq "cancel wrote nothing" "$(eget KCalc fx)" $((x0 - 400))
    # Wheel zoom in pan mode: out and back at the same anchor moves nothing;
    # a pan while zoomed out counts in canvas pixels.
    c panmode
    c "zoom 0.5 960 540"
    assert_eq "zoomed out, still in pan mode" "$(head -1 <<<"$LAST_STATE" | grep -c 'panmode.*zoom=0.5000')" 1
    c "panmode end 960 540"
    c state
    assert_eq "settled at 1:1" "$(sget zoom)" 1.0000
    assert_eq "no net move" "$(eget KCalc fx)" $((x0 - 400))
    c panmode
    c "zoom 0.5 960 540"
    c "pan -480 0"
    c "panmode end 960 540"
    c state
    assert_eq "closed after the zoomed pan" "$(sget visible)" false
    assert_near "half a screen at 0.5 is a full screen on the plane" "$(eget KCalc fx)" $((x0 - 400 - 960)) 1
    c "slide -960 0"
    if have_input; then
        # The real thing, in one fake-input session so the keys stay down:
        # chord down, two drags on the ground, chord up.
        printf 'key leftctrl down\nkey leftalt down\nkey p down\nsleep 400\ndrag 1700 900 1500 800\nsleep 200\ndrag 1500 800 1400 800\nsleep 200\nkey p up\nkey leftalt up\nkey leftctrl up\n' | input
        sleep 0.5
        c state
        assert_eq "closed when the chord was released" "$(sget visible)" false
        assert_near "two real drags pulled KCalc" "$(eget KCalc fx)" $((x0 - 400 - 300)) 3
        c "slide -700 -300"
    else
        skip "fakeinput not built (make tools)"
        c "slide -400 -200"
    fi
    c state
    assert_eq "back where it started" "$(eget KCalc fx)" "$x0"
}
