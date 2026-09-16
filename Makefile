# kwin-canvas: install the effect and the ground wallpaper as user packages.
# Both packages share shared/Ground.qml; `stage` copies it into each before install.

EFFECT_ID   := kwin-canvas
WALL_ID     := kwin-canvas-ground
BUILD       := build
KPT         := kpackagetool6
QDBUS       := qdbus6

.PHONY: all stage install uninstall reload enable disable status clean

all: install

stage:
	rm -rf $(BUILD)
	mkdir -p $(BUILD)
	cp -r effect $(BUILD)/effect
	cp -r wallpaper $(BUILD)/wallpaper
	cp shared/Ground.qml $(BUILD)/effect/contents/ui/Ground.qml
	cp shared/Ground.qml $(BUILD)/wallpaper/contents/ui/Ground.qml

install: stage
	$(KPT) --type KWin/Effect --upgrade $(BUILD)/effect 2>/dev/null || $(KPT) --type KWin/Effect --install $(BUILD)/effect
	$(KPT) --type Plasma/Wallpaper --upgrade $(BUILD)/wallpaper 2>/dev/null || $(KPT) --type Plasma/Wallpaper --install $(BUILD)/wallpaper

uninstall:
	-$(KPT) --type KWin/Effect --remove $(EFFECT_ID)
	-$(KPT) --type Plasma/Wallpaper --remove $(WALL_ID)

# Reload the effect in the running session after a code change.
reload: install
	-$(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect $(EFFECT_ID)
	$(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect $(EFFECT_ID)

# Turn the effect on in the live session. Disable the stock Zoom effect first if it owns Meta+wheel.
enable:
	kwriteconfig6 --file kwinrc --group Plugins --key $(EFFECT_ID)Enabled true
	$(QDBUS) org.kde.KWin /KWin org.kde.KWin.reconfigure

disable:
	kwriteconfig6 --file kwinrc --group Plugins --key $(EFFECT_ID)Enabled false
	$(QDBUS) org.kde.KWin /KWin org.kde.KWin.reconfigure

status:
	@echo "effect loaded: $$($(QDBUS) org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded $(EFFECT_ID))"
	@$(KPT) --type KWin/Effect --list 2>/dev/null | grep -i canvas || true
	@$(KPT) --type Plasma/Wallpaper --list 2>/dev/null | grep -i canvas || true

clean:
	rm -rf $(BUILD)
