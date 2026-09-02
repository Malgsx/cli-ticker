APP_NAME := CLITicker
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
TEST_BIN := $(BUILD_DIR)/tests/CLITickerTests
ICON := Assets/AppIcon/CLITicker.icns

.PHONY: all run test dist clean

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
	clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreServices "$<" -o "$(BIN)"
	printf '%s\n' \
	'<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0">' \
	'<dict>' \
	'  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	'  <key>CFBundleIdentifier</key><string>local.codex.cliticker</string>' \
	'  <key>CFBundleName</key><string>CLI</string>' \
	'  <key>CFBundlePackageType</key><string>APPL</string>' \
	'  <key>CFBundleIconFile</key><string>CLITicker</string>' \
	'  <key>CFBundleVersion</key><string>0.1.1</string>' \
	'  <key>CFBundleShortVersionString</key><string>0.1.1</string>' \
	'  <key>LSUIElement</key><true/>' \
	'</dict>' \
	'</plist>' > "$(APP_DIR)/Contents/Info.plist"

run: all
	open "$(APP_DIR)"

$(TEST_BIN): Tests/CLITickerTests.m Sources/CLITickerObjC/main.m
	mkdir -p "$(dir $(TEST_BIN))"
	clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreServices "$<" -o "$(TEST_BIN)"

test: $(TEST_BIN)
	"$(TEST_BIN)"

dist: all
	mkdir -p "$(BUILD_DIR)/dist"
	rm -f "$(BUILD_DIR)/dist/$(APP_NAME).app.tar.gz"
	tar -C "$(BUILD_DIR)" -czf "$(BUILD_DIR)/dist/$(APP_NAME).app.tar.gz" "$(APP_NAME).app"

clean:
	rm -rf "$(BUILD_DIR)"
