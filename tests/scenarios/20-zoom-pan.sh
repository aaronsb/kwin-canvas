scenario_desc="cursor-anchored zoom, pan, and zoom to fit"
run_scenario() {
    c open
    c "zoom 0.4 960 540"
    assert_near "zoom" "$(sget zoom)" 0.4 0.001
    assert_near "view x after zoom" "$(sget viewx)" -1440 1
    assert_near "view y after zoom" "$(sget viewy)" -810 1
    c "pan -300 -200"
    assert_near "view x after pan" "$(sget viewx)" -690 1
    assert_near "view y after pan" "$(sget viewy)" -310 1
    snap zoom-pan
    c extents
    assert_true "fit zoom below 1" "$(awk -v z="$(sget zoom)" 'BEGIN{print (z<1)}')" = 1
    snap extents
    c cancel
}
