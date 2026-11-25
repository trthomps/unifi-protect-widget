APP := build/Protect Cameras.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app install run print watch clean

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
