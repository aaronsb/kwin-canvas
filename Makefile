# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
# kwin-canvas — an infinite canvas for KWin as a QML effect plus a ground wallpaper,
# a panel applet and a terminal CLI.
# `make` alone prints this help. Targets are documented with a trailing `## text`.

EFFECT_ID   := kwin-canvas
WALL_ID     := kwin-canvas-ground
APPLET_ID   := org.kde.kwin.canvas.toggle
CLI         := tools/kwin-canvas
BIN_DIR     := $(HOME)/.local/bin
PLUGIN_ID   := kwin_canvas_passthrough
BUILD       := build
PLUGIN_BUILD := $(BUILD)/plugin
AUR_PT_DIR  := $(BUILD)/aur-passthrough
DIST        := dist
VERSION     := $(shell cat VERSION)
KPT         := kpackagetool6
QDBUS       := qdbus6
NEST        := ./dev/nest.sh
PYTHON      := python3

.DEFAULT_GOAL := help
.PHONY: help deps deps-install install uninstall install-system uninstall-system reload enable disable status \
        tools fixtures play nest nest-down nest-clients nest-fixtures nest-reload nest-shot nest-log nest-clean nest-cmd \
        test golden demo video clean stage dist pkgbuild aur aur-passthrough release tour \
        plugin plugin-try plugin-install-system plugin-status

help: ## Show this help
	@echo "kwin-canvas"
	@echo
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Short form: ./configure.sh install | uninstall | enable | disable | status | try"
	@echo "Nest commands take NEST_NAME=<name> to run a second nest; tests use NEST_NAME=test."
	@echo "Debug commands for the nest: make nest-cmd CMD=\"zoom 0.4 960 540\"  (see docs/testing.md)"

# ---- dependencies -----------------------------------------------------------
deps: ## Check required tools; print what is missing and how to install it
	@dev/deps.sh

deps-install: ## Install missing dependencies with pacman (asks for sudo)
	@dev/deps.sh --install

# ---- packages ---------------------------------------------------------------
stage:
	rm -rf $(BUILD)/effect $(BUILD)/wallpaper $(BUILD)/applet
	mkdir -p $(BUILD)
	cp -r effect $(BUILD)/effect
	cp -r wallpaper $(BUILD)/wallpaper
	cp -r applet $(BUILD)/applet
	cp shared/Ground.qml $(BUILD)/effect/contents/ui/Ground.qml
	cp shared/Ground.qml $(BUILD)/wallpaper/contents/ui/Ground.qml

install: stage ## Install the effect, the ground wallpaper and the applet as user packages, and the CLI into ~/.local/bin
	@$(KPT) --type KWin/Effect --upgrade $(BUILD)/effect >/dev/null 2>&1 || $(KPT) --type KWin/Effect --install $(BUILD)/effect >/dev/null
	@$(KPT) --type Plasma/Wallpaper --upgrade $(BUILD)/wallpaper >/dev/null 2>&1 || $(KPT) --type Plasma/Wallpaper --install $(BUILD)/wallpaper >/dev/null
	@$(KPT) --type Plasma/Applet --upgrade $(BUILD)/applet >/dev/null 2>&1 || $(KPT) --type Plasma/Applet --install $(BUILD)/applet >/dev/null
	@mkdir -p $(BIN_DIR) && install -m 755 $(CLI) $(BIN_DIR)/kwin-canvas
	@echo "installed for $$USER: $(EFFECT_ID), $(WALL_ID), $(APPLET_ID), $(BIN_DIR)/kwin-canvas"

uninstall: disable ## Turn the effect off and remove the user packages and the CLI
	@$(KPT) --type KWin/Effect --remove $(EFFECT_ID) >/dev/null 2>&1 && echo "removed: $(EFFECT_ID)" || echo "not installed: $(EFFECT_ID)"
	@$(KPT) --type Plasma/Wallpaper --remove $(WALL_ID) >/dev/null 2>&1 && echo "removed: $(WALL_ID)" || echo "not installed: $(WALL_ID)"
	@$(KPT) --type Plasma/Applet --remove $(APPLET_ID) >/dev/null 2>&1 && echo "removed: $(APPLET_ID)" || echo "not installed: $(APPLET_ID)"
	@rm -f $(BIN_DIR)/kwin-canvas

# System-wide layout, the same paths kpackagetool6 --global uses; KPackage
# finds them through XDG_DATA_DIRS. DESTDIR is for distro packaging.
SYS_EFFECT  := $(DESTDIR)/usr/share/kwin/effects/$(EFFECT_ID)
SYS_WALL    := $(DESTDIR)/usr/share/plasma/wallpapers/$(WALL_ID)
SYS_APPLET  := $(DESTDIR)/usr/share/plasma/plasmoids/$(APPLET_ID)
SYS_BIN     := $(DESTDIR)/usr/bin/kwin-canvas

install-system: stage ## Copy the three packages into DESTDIR/usr/share and the CLI into DESTDIR/usr/bin (for a PKGBUILD or a .deb rule)
	rm -rf $(SYS_EFFECT) $(SYS_WALL) $(SYS_APPLET)
	mkdir -p $(dir $(SYS_EFFECT)) $(dir $(SYS_WALL)) $(dir $(SYS_APPLET)) $(dir $(SYS_BIN))
	cp -r $(BUILD)/effect $(SYS_EFFECT)
	cp -r $(BUILD)/wallpaper $(SYS_WALL)
	cp -r $(BUILD)/applet $(SYS_APPLET)
	find $(SYS_EFFECT) $(SYS_WALL) $(SYS_APPLET) -type d -exec chmod 755 {} +
	find $(SYS_EFFECT) $(SYS_WALL) $(SYS_APPLET) -type f -exec chmod 644 {} +
	install -m 755 $(CLI) $(SYS_BIN)
	@echo "installed: $(SYS_EFFECT) $(SYS_WALL) $(SYS_APPLET) $(SYS_BIN)"

uninstall-system: ## Remove the system-wide copies
	rm -rf $(SYS_EFFECT) $(SYS_WALL) $(SYS_APPLET) $(SYS_BIN)

reload: install ## Reinstall and reload the effect in the live session (QML changes need a KWin restart)
	-$(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect $(EFFECT_ID)
	$(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect $(EFFECT_ID)

# A plain /KWin reconfigure never loads a newly enabled effect; ask by name.
enable: ## Turn the effect on in the live session (disable the stock Zoom effect if it owns Meta+wheel)
	@kwriteconfig6 --file kwinrc --group Plugins --key $(EFFECT_ID)Enabled true
	@if $(QDBUS) org.kde.KWin /KWin org.kde.KWin.supportInformation >/dev/null 2>&1; then \
	    $(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect $(EFFECT_ID) >/dev/null; \
	    if [ "$$($(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded $(EFFECT_ID))" = true ]; then \
	        echo "enabled and loaded. Meta+Ctrl+Alt+Space steps out to the overworld and back in; Esc cancels."; \
	    else \
	        echo "enabled in kwinrc but KWin did not load it; see: journalctl --user -b _COMM=kwin_wayland | grep -i canvas"; exit 1; \
	    fi; \
	else echo "enabled in kwinrc; it loads with the next Plasma session"; fi

disable: ## Turn the effect off in the live session
	@kwriteconfig6 --file kwinrc --group Plugins --key $(EFFECT_ID)Enabled false
	@$(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect $(EFFECT_ID) >/dev/null 2>&1 || true
	@echo "disabled. Windows left off-screen come back through the task manager."

status: ## Show whether the packages are installed, enabled and loaded
	@echo "effect package:    $$($(KPT) --type KWin/Effect --list 2>/dev/null | grep -x $(EFFECT_ID) || echo not installed)"
	@echo "wallpaper package: $$($(KPT) --type Plasma/Wallpaper --list 2>/dev/null | grep -x $(WALL_ID) || echo not installed)"
	@echo "applet package:    $$($(KPT) --type Plasma/Applet --list 2>/dev/null | grep -x $(APPLET_ID) || echo not installed)"
	@echo "cli:               $$(command -v kwin-canvas 2>/dev/null || echo not on PATH)"
	@echo "enabled in kwinrc: $$(kreadconfig6 --file kwinrc --group Plugins --key $(EFFECT_ID)Enabled --default false)"
	@echo "loaded in KWin:    $$($(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded $(EFFECT_ID) 2>/dev/null || echo no session)"
	@$(MAKE) -s plugin-status

# ---- pass-through plugin (optional) -----------------------------------------
# A binary KWin plugin that hands pointer and key input to the real windows
# while the canvas is open. Built against the installed KWin; KWin loads it
# only when the versions match, and the effect only uses it when it answers
# the probe, so a stale build means an overworld without pass-through, never
# a broken canvas.
plugin: ## Build the optional pass-through plugin against the installed KWin (build/plugin/bin/kwin/plugins)
	cmake -S plugin -B $(PLUGIN_BUILD) -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >/dev/null
	cmake --build $(PLUGIN_BUILD) -j | grep -E "error|warning:|Built target $(PLUGIN_ID)$$" || true

plugin-try: ## Build the plugin when KWin's headers and cmake are here; otherwise say so and carry on
	@if [ -f /usr/include/kwin/plugin.h ] && command -v cmake >/dev/null 2>&1; then $(MAKE) -s plugin; \
	else echo "pass-through plugin: KWin headers or cmake missing, skipped"; fi

plugin-install-system: plugin ## Install the plugin into DESTDIR/usr/lib/qt6/plugins/kwin/plugins (for a PKGBUILD)
	DESTDIR=$(DESTDIR) cmake --install $(PLUGIN_BUILD) >/dev/null
	@echo "installed: $(DESTDIR)/usr/lib/qt6/plugins/kwin/plugins/$(PLUGIN_ID).so"

plugin-status: ## Whether the pass-through plugin is built, installed, and answering in the running KWin
	@echo "plugin built:      $$([ -f $(PLUGIN_BUILD)/bin/kwin/plugins/$(PLUGIN_ID).so ] && echo yes || echo no)"
	@echo "plugin installed:  $$(ls /usr/lib/qt6/plugins/kwin/plugins/$(PLUGIN_ID).so 2>/dev/null || echo no)"
	@echo "running KWin:      $$(kwin_wayland --version 2>/dev/null | head -1 || echo unknown)"
	@echo "plugin answers:    $$($(QDBUS) org.kde.KWin /KWinCanvas org.kde.kwin.canvas.Passthrough.probe 2>/dev/null || echo 'no: not loaded (built for another KWin?), or no session')"

# ---- tools and fixtures -----------------------------------------------------
tools: ## Build the fake-input client used by tests and demos (build/tools/fakeinput)
	$(MAKE) -C tools

fixtures: ## Generate the test fixtures (wallpaper, tile, text files)
	$(PYTHON) tests/fixtures/gen.py

# ---- nested compositor ------------------------------------------------------
nest: ## Start the nested KWin with the effect and plasmashell inside (own D-Bus bus and config)
	$(NEST) up
	@echo
	@echo "Next:  make nest-fixtures          windows to play with"
	@echo "       make nest-cmd CMD=open      open the canvas (or Ctrl+Alt+Space inside the window)"
	@echo "       make nest-down              stop it"

play: install fixtures ## Nest with the fixture apps arranged and the canvas open (make play ARGS=--closed for 1:1)
	dev/play.sh $(ARGS)

nest-down: ## Stop the nested KWin
	$(NEST) down

nest-clients: ## Launch kcalc, konsole, kwrite into the nest
	$(NEST) clients

nest-fixtures: fixtures ## Launch the fixture set of KDE apps into the nest
	$(NEST) fixtures

nest-reload: ## Reinstall, restart the nest, relaunch clients
	$(NEST) reload

nest-shot: ## Screenshot the nest (prints the file)
	$(NEST) shot

nest-log: ## Tail the nest's KWin log
	$(NEST) log

nest-clean: ## Kill leftovers of nests whose state is gone (portals, activity daemons, orphaned compositors)
	$(NEST) clean

nest-cmd: ## Send a debug command: make nest-cmd CMD="zoom 0.4 960 540"
	$(NEST) cmd "$(CMD)"

# ---- tests and demos --------------------------------------------------------
test: install fixtures plugin-try ## Run the scenarios against a dedicated test nest (NEST_NAME=test)
	tests/run.sh $(ARGS)

golden: install fixtures ## Re-record the golden screenshots from the current build
	UPDATE_GOLDEN=1 tests/run.sh $(ARGS)

demo: install fixtures tools ## Drive a scripted session with real input; screenshots and frames to build/demo
	demo/demo.sh

tour: install fixtures ## Regenerate the screenshot tour images in docs/images
	docs/tour.sh

video: ## Assemble build/demo frames into demo.mp4 and demo.gif (run `make demo` first)
	demo/demo.sh --video-only

# ---- distribution -----------------------------------------------------------
dist: stage ## Tarballs of the three packages for kpackagetool6 or the KDE Store (dist/)
	rm -rf $(DIST); mkdir -p $(DIST)
	tar -C $(BUILD)/effect -czf $(DIST)/kwin-canvas-$(VERSION).kwineffect.tar.gz .
	tar -C $(BUILD)/wallpaper -czf $(DIST)/kwin-canvas-ground-$(VERSION).tar.gz .
	tar -C $(BUILD)/applet -czf $(DIST)/kwin-canvas-toggle-$(VERSION).tar.gz .
	@cd $(DIST) && sha256sum *.tar.gz > SHA256SUMS && cat SHA256SUMS
	@echo
	@echo "install:  kpackagetool6 --type KWin/Effect --install $(DIST)/kwin-canvas-$(VERSION).kwineffect.tar.gz"
	@echo "          kpackagetool6 --type Plasma/Wallpaper --install $(DIST)/kwin-canvas-ground-$(VERSION).tar.gz"
	@echo "          kpackagetool6 --type Plasma/Applet --install $(DIST)/kwin-canvas-toggle-$(VERSION).tar.gz"

pkgbuild: ## Write dist/PKGBUILD (effect) and dist/passthrough/PKGBUILD (plugin) for the AUR at this VERSION
	mkdir -p $(DIST)/passthrough
	sed 's/@VERSION@/$(VERSION)/g' packaging/PKGBUILD.in > $(DIST)/PKGBUILD
	cp packaging/kwin-canvas.install $(DIST)/kwin-canvas.install
	sed 's/@VERSION@/$(VERSION)/g' packaging/PKGBUILD-passthrough.in > $(DIST)/passthrough/PKGBUILD
	cp packaging/kwin-canvas-passthrough.install $(DIST)/passthrough/kwin-canvas-passthrough.install
	@echo "dist/PKGBUILD and dist/passthrough/PKGBUILD written; after the v$(VERSION) tag is on GitHub: updpkgsums && makepkg -si in each"

# The AUR repository is a git remote of its own; the package there is the
# generated PKGBUILD, its install file and .SRCINFO, with checksums taken
# from the GitHub tag tarball, so `make release` comes first.
AUR_DIR := $(BUILD)/aur
aur: pkgbuild ## Publish or update the AUR package from the v$(VERSION) tag (run after make release)
	@[ -d $(AUR_DIR)/.git ] || git clone -q ssh://aur@aur.archlinux.org/kwin-canvas.git $(AUR_DIR)
	@cd $(AUR_DIR) && git pull -q --rebase 2>/dev/null || true
	cp $(DIST)/PKGBUILD $(DIST)/kwin-canvas.install $(AUR_DIR)/
	cd $(AUR_DIR) && updpkgsums && makepkg --printsrcinfo > .SRCINFO
	cd $(AUR_DIR) && git add PKGBUILD kwin-canvas.install .SRCINFO && git commit -q -m "kwin-canvas $(VERSION)" && git push -q origin HEAD:master
	@echo "published: https://aur.archlinux.org/packages/kwin-canvas"

aur-passthrough: pkgbuild ## Publish or update the AUR package for the pass-through plugin (run after make release)
	@[ -d $(AUR_PT_DIR)/.git ] || git clone -q ssh://aur@aur.archlinux.org/kwin-canvas-passthrough.git $(AUR_PT_DIR)
	@cd $(AUR_PT_DIR) && git pull -q --rebase 2>/dev/null || true
	cp $(DIST)/passthrough/PKGBUILD $(DIST)/passthrough/kwin-canvas-passthrough.install $(AUR_PT_DIR)/
	cd $(AUR_PT_DIR) && updpkgsums && makepkg --printsrcinfo > .SRCINFO
	cd $(AUR_PT_DIR) && git add PKGBUILD kwin-canvas-passthrough.install .SRCINFO && git commit -q -m "kwin-canvas-passthrough $(VERSION)" && git push -q origin HEAD:master
	@echo "published: https://aur.archlinux.org/packages/kwin-canvas-passthrough"

release: dist ## Tag v$(VERSION) and publish a GitHub release with the tarballs (needs a clean tree)
	@git diff --quiet || { echo "uncommitted changes"; exit 1; }
	git tag -a v$(VERSION) -m "kwin-canvas $(VERSION)"
	git push origin main v$(VERSION)
	gh release create v$(VERSION) $(DIST)/*.tar.gz $(DIST)/SHA256SUMS --title "kwin-canvas $(VERSION)" --notes-file docs/release-notes.md

clean: ## Remove build output
	rm -rf $(BUILD) $(DIST)
	@echo "the AUR checkouts under build/ went with it; make aur clones them again" 
