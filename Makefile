APP_NAME := CLITicker
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
ICON := Assets/AppIcon/CLITicker.icns

.PHONY: all run dist clean

all: $(BIN)

$(ICON): scripts/generate_icon_assets.py
	python3 scripts/generate_icon_assets.py
	iconutil -c icns Assets/AppIcon/CLITicker.iconset -o "$(ICON)"

$(BIN): Sources/CLITickerObjC/main.m $(ICON)
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	mkdir -p "$(APP_DIR)/Contents/Resources/Logos"
	cp -R Assets/Logos/. "$(APP_DIR)/Contents/Resources/Logos/"
	cp "$(ICON)" "$(APP_DIR)/Contents/Resources/CLITicker.icns"
	cp Assets/AppIcon/CLIStatusTemplate.png "$(APP_DIR)/Contents/Resources/CLIStatusTemplate.png"
	clang -fobjc-arc -framework AppKit -framework Foundation "$<" -o "$(BIN)"
	printf '%s\n' \
	'<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0">' \
	'<dict>' \
	'  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	'  <key>CFBundleIdentifier</key><string>local.codex.cliticker</string>' \
	'  <key>CFBundleName</key><string>CLI Ticker</string>' \
	'  <key>CFBundlePackageType</key><string>APPL</string>' \
	'  <key>CFBundleIconFile</key><string>CLITicker</string>' \
	'  <key>CFBundleVersion</key><string>0.1.0</string>' \
	'  <key>CFBundleShortVersionString</key><string>0.1.0</string>' \
	'  <key>LSUIElement</key><true/>' \
	'</dict>' \
	'</plist>' > "$(APP_DIR)/Contents/Info.plist"

run: all
	open "$(APP_DIR)"

dist: all
	mkdir -p "$(BUILD_DIR)/dist"
	rm -f "$(BUILD_DIR)/dist/$(APP_NAME).zip"
	ditto -c -k --keepParent "$(APP_DIR)" "$(BUILD_DIR)/dist/$(APP_NAME).zip"

clean:
	rm -rf "$(BUILD_DIR)"
