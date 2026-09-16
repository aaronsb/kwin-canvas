# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="pushing the pointer into the configured corner opens the canvas"
run_scenario() {
    if ! have_input; then skip "fakeinput not built (make tools)"; return; fi
    c state
    assert_eq "closed to start" "$(sget visible)" false
    input move 0 0
    for _ in 1 2 3 4 5 6; do input rel -20 -20; sleep 0.08; done
    sleep 0.5; c state
    assert_eq "corner opened the canvas" "$(sget visible)" true
    input move 960 540
    input key esc
    sleep 0.3; c state
    assert_eq "escape closed it" "$(sget visible)" false
}
