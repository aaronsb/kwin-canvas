scenario_desc="moving a window on the canvas lands it there on apply"
run_scenario() {
    open_1to1
    c "placeby KCalc 1500 700"
    assert_eq "KCalc canvas x" "$(eget KCalc x)" 1500
    c commit
    assert_eq "KCalc frame x" "$(eget KCalc fx)" 1500
    assert_eq "KCalc frame y" "$(eget KCalc fy)" 700
    open_1to1
    c "placeby KCalc 100 120"
    c commit
    assert_eq "KCalc frame x restored" "$(eget KCalc fx)" 100
}
