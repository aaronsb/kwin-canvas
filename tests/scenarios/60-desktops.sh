scenario_desc="desktops are frame groups; a window in another desktop's frame moves there"
run_scenario() {
    open_1to1
    c "adddesktop 0"
    sleep 0.6
    c state
    assert_eq "three desktops" "$(sget ndesktops)" 3
    local tx ty; tx=$(tget 1 x); ty=$(tget 1 y)
    assert_true "inserted desktop placed apart" "$tx" != "$(tget 0 x)"
    c "placeby KCalc $((tx + 200)) $((ty + 200))"
    c extents
    snap three-desktops
    c commit
    assert_eq "KCalc on inserted desktop" "$(eget KCalc desktop)" "$(tget 1 name)"
    assert_eq "KCalc frame x relative to its frame" "$(eget KCalc fx)" 200
    c "desktop 1"
    assert_near "view follows desktop" "$(sget viewx)" "$tx" 0.5
    c "desktop 0"
    open_1to1
    c "placeby KCalc 100 120"
    c commit
    assert_eq "KCalc back on desktop 1" "$(eget KCalc desktop)" "$(tget 0 name)"
    c "rmdesktop 1"
    sleep 0.6
    c state
    assert_eq "two desktops" "$(sget ndesktops)" 2
}
