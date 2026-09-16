scenario_desc="resizing from the canvas commands the client and follows what it accepts"
run_scenario() {
    open_1to1
    local i; i=$(eget sample.txt index)
    c "resize $i 900 600"
    sleep 0.6
    c state
    assert_eq "KWrite width" "$(eget sample.txt w)" 900
    assert_eq "KWrite height" "$(eget sample.txt h)" 600
    snap resized
    c commit
    open_1to1
    c "resize $i 700 520"
    sleep 0.6
    c commit
    open_1to1
    assert_eq "KWrite width restored" "$(eget sample.txt w)" 700
    c cancel
}
