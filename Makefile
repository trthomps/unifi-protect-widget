APP := build/Protect Cameras.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app install run print watch clean kde-install kde-uninstall kde-test

app:
	./scripts/build-app.sh

install: app
	mkdir -p "$(INSTALL_DIR)"
	-pkill -x ProtectCameras
	rm -rf "$(INSTALL_DIR)/Protect Cameras.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/Protect Cameras.app"
	@echo "Installed to $(INSTALL_DIR)/Protect Cameras.app"

run: app
	-pkill -x ProtectCameras
	open "$(APP)"

print:
	swift run -c release ProtectCameras --print

watch:
	swift run -c release ProtectCameras --watch

clean:
	rm -rf .build build

# KDE Plasma 6 widget (see kde/README.md)
KDE_ID := dev.protectcameras.plasmoid

kde-install:
	kpackagetool6 -t Plasma/Applet -u kde/package >/dev/null 2>&1 || kpackagetool6 -t Plasma/Applet -i kde/package
	@echo "Installed. Add \"Protect Cameras\" from Add Widgets. After an upgrade, restart plasmashell: systemctl --user restart plasma-plasmashell"

kde-uninstall:
	kpackagetool6 -t Plasma/Applet -r $(KDE_ID)

kde-test:
	node kde/test/protect.test.js
	python3 kde/test/bridge_test.py
