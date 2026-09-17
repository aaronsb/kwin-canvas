# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="apply writes canvas minus the frame target as window geometry; the camera is not involved"
run_scenario() {
    open_1to1
    c "pan -500 -300"
    c commit
    assert_eq "pan alone moves nothing: KCalc frame x" "$(eget KCalc fx)" 100
    assert_near "camera returned to the frames" "$(sget viewx)" 0 0.5
    # Frames carry their windows by default: the group moves on the plane,
    # nothing changes on screen.
    open_1to1
    c "frames 500 300"
    assert_eq "KCalc rode with the frames" "$(eget KCalc x)" 600
    c commit
    assert_eq "visible" "$(sget visible)" false
    assert_near "view follows the frames x" "$(sget viewx)" 500 0.5
    assert_eq "KCalc frame x unchanged" "$(eget KCalc fx)" 100
    assert_eq "Gwenview frame x unchanged" "$(eget Gwenview fx)" 1400
    c resetview
    assert_near "view x reset" "$(sget viewx)" 0 0.5
    # Decoupled: the frames move over the windows.
    kwriteconfig6 --file "$CONF/kwinrc" --group Effect-kwin-canvas --key FramesCarryWindows false
    open_1to1
    c "frames 500 300"
    c commit
    assert_eq "KCalc frame x" "$(eget KCalc fx)" -400
    assert_eq "KCalc frame y" "$(eget KCalc fy)" -180
    assert_eq "Gwenview frame x" "$(eget Gwenview fx)" 900
    snap after-commit-1to1
    c "shift 500 300"
    assert_eq "KCalc frame x restored" "$(eget KCalc fx)" 100
    assert_near "view x restored" "$(sget viewx)" 0 0.5
    kwriteconfig6 --file "$CONF/kwinrc" --group Effect-kwin-canvas --key FramesCarryWindows true
}
