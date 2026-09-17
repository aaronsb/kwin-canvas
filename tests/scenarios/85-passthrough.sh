# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
scenario_desc="pass-through plugin: in pan mode clicks, drags and the wheel reach the real windows; the ground still pans"
# The plugin's own state line: active, camera, grab, hover.
pt_state() { nq org.kde.KWin /KWinCanvas org.kde.kwin.canvas.Passthrough.state; }
aget() { sed -n 's/.*active="\(.*\)".*/\1/p' <<<"$(head -1 <<<"$LAST_STATE")"; }
# rmse between two crops of two screenshots; the region is WxH+X+Y.
region_rmse() {   # before after region
    magick "$1" -crop "$3" +repage "$OUT/pt-a.png"
    magick "$2" -crop "$3" +repage "$OUT/pt-b.png"
    { magick compare -metric RMSE "$OUT/pt-a.png" "$OUT/pt-b.png" null: 2>&1 || true; } | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p'
}
changed() { awk -v m="$1" 'BEGIN{print (m>0.005)}'; }
run_scenario() {
    if ! have_input; then skip "fakeinput not built (make tools)"; return; fi
    if ! nq org.kde.KWin /KWinCanvas org.kde.kwin.canvas.Passthrough.probe >/dev/null 2>&1; then
        skip "pass-through plugin not loaded (make plugin)"; return
    fi
    c "activate Dolphin"
    shot "$OUT/pt-before.png" >/dev/null
    c panmode; sleep 0.5; c state
    assert_eq "pan mode with pass-through" "$(head -1 <<<"$LAST_STATE" | grep -c 'panmode passthrough')" 1
    assert_eq "plugin switched on" "$(pt_state | grep -c 'active=true')" 1
    # Hover follows the window under the pointer and clears over the ground.
    input move 900 400; sleep 0.3
    assert_eq "hover reaches KWrite" "$(pt_state | grep -c 'hover=sample.txt')" 1
    input move 1700 1000; sleep 0.3
    assert_eq "ground clears the hover" "$(pt_state | grep -c 'hover=-')" 1
    # A click raises and focuses; the thumbnails restack.
    printf 'move 900 400\nclick\n' | input; sleep 0.8; c state
    assert_eq "click focuses KWrite" "$(aget)" "sample.txt — KWrite"
    assert_eq "KWrite on top" "$(grep '^  \[' <<<"$LAST_STATE" | tail -1 | grep -c KWrite)" 1
    # A drag inside KWrite selects text; the wheel over Konsole scrolls it.
    printf 'drag 760 392 1000 424\n' | input; sleep 0.5
    printf 'move 400 900\nwheel 3\n' | input; sleep 0.5
    shot "$OUT/pt-after.png" >/dev/null
    assert_eq "drag selected text in KWrite" "$(changed "$(region_rmse "$OUT/pt-before.png" "$OUT/pt-after.png" 600x260+690+380)")" 1
    assert_eq "wheel scrolled Konsole" "$(changed "$(region_rmse "$OUT/pt-before.png" "$OUT/pt-after.png" 500x300+110+680)")" 1
    # The ground still pans, and settling releases the plugin.
    printf 'drag 1700 1000 1500 900\n' | input; sleep 0.4; c state
    assert_near "ground drag pans x" "$(sget viewx)" 200 2
    assert_near "ground drag pans y" "$(sget viewy)" 100 2
    c "panmode end"; c state
    assert_eq "settled" "$(sget visible)" false
    assert_eq "plugin switched off" "$(pt_state | grep -c 'active=false')" 1
    c "slide -200 -100"
    # Leave the fixtures as found: scroll Konsole back, drop the selection.
    c panmode; sleep 0.4
    printf 'move 400 900\nwheel -3\nmove 900 300\nclick\n' | input; sleep 0.4
    c "panmode end"
    c state
    assert_eq "layout kept" "$(eget KCalc fx)" 100
}
