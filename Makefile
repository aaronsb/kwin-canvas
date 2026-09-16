# SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
# kwin-canvas — an infinite canvas for KWin as a QML effect plus a ground wallpaper.
# `make` alone prints this help. Targets are documented with a trailing `## text`.

EFFECT_ID   := kwin-canvas
WALL_ID     := kwin-canvas-ground
BUILD       := build
DIST        := dist
VERSION     := $(shell cat VERSION)
KPT         := kpackagetool6
QDBUS       := qdbus6
NEST        := ./dev/nest.sh
PYTHON      := python3

.DEFAULT_GOAL := help
.PHONY: help deps deps-install install uninstall reload enable disable status \
        tools fixtures play nest nest-down nest-clients nest-fixtures nest-reload nest-shot nest-log nest-clean nest-cmd \
        test golden demo video clean stage dist release

help: ## Show this help
	@echo "kwin-canvas"
	@echo
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Nest commands take NEST_NAME=<name> to run a second nest; tests use NEST_NAME=test."
	@echo "Debug commands for the nest: make nest-cmd CMD=\"zoom 0.4 960 540\"  (see docs/testing.md)"

# ---- dependencies -----------------------------------------------------------
deps: ## Check required tools; print what is missing and how to install it
	@dev/deps.sh

deps-install: ## Install missing dependencies with pacman (asks for sudo)
	@dev/deps.sh --install

# ---- packages ---------------------------------------------------------------
stage:
	rm -rf $(BUILD)/effect $(BUILD)/wallpaper
	mkdir -p $(BUILD)
	cp -r effect $(BUILD)/effect
	cp -r wallpaper $(BUILD)/wallpaper
	cp shared/Ground.qml $(BUILD)/effect/contents/ui/Ground.qml
	cp shared/Ground.qml $(BUILD)/wallpaper/contents/ui/Ground.qml

install: stage ## Install the effect and the ground wallpaper as user packages
	$(KPT) --type KWin/Effect --upgrade $(BUILD)/effect 2>/dev/null || $(KPT) --type KWin/Effect --install $(BUILD)/effect
	$(KPT) --type Plasma/Wallpaper --upgrade $(BUILD)/wallpaper 2>/dev/null || $(KPT) --type Plasma/Wallpaper --install $(BUILD)/wallpaper

uninstall: ## Remove both packages
	-$(KPT) --type KWin/Effect --remove $(EFFECT_ID)
	-$(KPT) --type Plasma/Wallpaper --remove $(WALL_ID)

reload: install ## Reinstall and reload the effect in the live session (QML changes need a KWin restart)
	-$(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect $(EFFECT_ID)
	$(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect $(EFFECT_ID)

enable: ## Turn the effect on in the live session (disable the stock Zoom effect if it owns Meta+wheel)
	kwriteconfig6 --file kwinrc --group Plugins --key $(EFFECT_ID)Enabled true
	$(QDBUS) org.kde.KWin /KWin org.kde.KWin.reconfigure

disable: ## Turn the effect off in the live session
	kwriteconfig6 --file kwinrc --group Plugins --key $(EFFECT_ID)Enabled false
	$(QDBUS) org.kde.KWin /KWin org.kde.KWin.reconfigure

status: ## Show whether the packages are installed and the effect loaded
	@echo "effect loaded in live session: $$($(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded $(EFFECT_ID) 2>/dev/null || echo unknown)"
	@$(KPT) --type KWin/Effect --list 2>/dev/null | grep -i canvas || echo "effect package: not installed"
	@$(KPT) --type Plasma/Wallpaper --list 2>/dev/null | grep -i canvas || echo "wallpaper package: not installed"

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
test: install fixtures ## Run the scenarios against a dedicated test nest (NEST_NAME=test)
	tests/run.sh $(ARGS)

golden: install fixtures ## Re-record the golden screenshots from the current build
	UPDATE_GOLDEN=1 tests/run.sh $(ARGS)

demo: install fixtures tools ## Drive a scripted session with real input; screenshots and frames to build/demo
	demo/demo.sh

video: ## Assemble build/demo frames into demo.mp4 and demo.gif (run `make demo` first)
	demo/demo.sh --video-only

# ---- distribution -----------------------------------------------------------
dist: stage ## Tarballs of both packages for kpackagetool6 or the KDE Store (dist/)
	rm -rf $(DIST); mkdir -p $(DIST)
	tar -C $(BUILD)/effect -czf $(DIST)/kwin-canvas-$(VERSION).kwineffect.tar.gz .
	tar -C $(BUILD)/wallpaper -czf $(DIST)/kwin-canvas-ground-$(VERSION).tar.gz .
	@cd $(DIST) && sha256sum *.tar.gz > SHA256SUMS && cat SHA256SUMS
	@echo
	@echo "install:  kpackagetool6 --type KWin/Effect --install $(DIST)/kwin-canvas-$(VERSION).kwineffect.tar.gz"
	@echo "          kpackagetool6 --type Plasma/Wallpaper --install $(DIST)/kwin-canvas-ground-$(VERSION).tar.gz"

release: dist ## Tag v$(VERSION) and publish a GitHub release with the tarballs (needs a clean tree)
	@git diff --quiet || { echo "uncommitted changes"; exit 1; }
	git tag -a v$(VERSION) -m "kwin-canvas $(VERSION)"
	git push origin main v$(VERSION)
	gh release create v$(VERSION) $(DIST)/*.tar.gz $(DIST)/SHA256SUMS --title "kwin-canvas $(VERSION)" --notes-file docs/release-notes.md

clean: ## Remove build output
	rm -rf $(BUILD) $(DIST)
