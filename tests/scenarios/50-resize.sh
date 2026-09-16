scenario_desc="resizing from the canvas commands the client and follows what it accepts"
run_scenario() {
    c open
    local i; i=$(eget sample.txt index)
    c "resize $i 900 600"
    sleep 0.6
    c state
    assert_eq "KWrite width" "$(eget sample.txt w)" 900
    assert_eq "KWrite height" "$(eget sample.txt h)" 600
    snap resized
    c commit
    c open
    c "resize $i 700 520"
    sleep 0.6
    c commit
    c open
    assert_eq "KWrite width restored" "$(eget sample.txt w)" 700
    c cancel
}
