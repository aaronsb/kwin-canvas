scenario_desc="opening at 1:1 shows every window where it is"
run_scenario() {
    c open
    assert_eq "visible" "$(sget visible)" true
    assert_eq "zoom" "$(sget zoom)" 1.0000
    assert_eq "entries" "$(sget entries)" 5
    assert_eq "KCalc canvas x" "$(eget KCalc x)" 100
    assert_eq "KCalc frame x" "$(eget KCalc fx)" 100
    snap open-1to1
    c cancel
    assert_eq "visible after cancel" "$(sget visible)" false
}
