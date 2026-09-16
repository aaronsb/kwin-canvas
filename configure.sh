#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# kwin-canvas, the short way. Each command is one Makefile target; `make`
# alone lists them all.
#
#   ./configure.sh install      install the effect and the ground wallpaper for this user, and turn the effect on
#   ./configure.sh uninstall    turn it off and remove both packages
#   ./configure.sh enable       turn the effect on in the running session
#   ./configure.sh disable      turn it off
#   ./configure.sh status       what is installed, enabled and loaded
#   ./configure.sh try          a nested KWin with sample windows and the canvas open (make play)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v make >/dev/null 2>&1 || { echo "make is missing (Arch: pacman -S make)"; exit 1; }
case "${1:-}" in
    install)   make -s install enable ;;
    uninstall) make -s uninstall ;;
    enable|disable|status) make -s "$1" ;;
    try)       make -s play ;;
    *) sed -n '5,13p' "$0"; exit 1 ;;
esac
