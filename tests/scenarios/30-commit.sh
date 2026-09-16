scenario_desc="apply writes canvas minus the frame target as window geometry; the camera is not involved"
run_scenario() {
    open_1to1
    c "pan -500 -300"
    c commit
    assert_eq "pan alone moves nothing: KCalc frame x" "$(eget KCalc fx)" 100
    assert_near "camera returned to the frames" "$(sget viewx)" 0 0.5
    open_1to1
    c "frames 500 300"
    c commit
    assert_eq "visible" "$(sget visible)" false
    assert_near "view follows the frames x" "$(sget viewx)" 500 0.5
    assert_eq "KCalc frame x" "$(eget KCalc fx)" -400
    assert_eq "KCalc frame y" "$(eget KCalc fy)" -180
    assert_eq "Gwenview frame x" "$(eget Gwenview fx)" 900
    snap after-commit-1to1
    c "shift 500 300"
    assert_eq "KCalc frame x restored" "$(eget KCalc fx)" 100
    assert_near "view x restored" "$(sget viewx)" 0 0.5
}
