# Override any of these on the command line, e.g. `make BUNDLE_ID=com.example.cli`.
# Changing them does not trigger a rebuild; run `make clean` first.
APP_NAME := CLITicker
DISPLAY_NAME := CLI
BUNDLE_ID := local.codex.cliticker
VERSION := 0.1.1
# Set to a "Developer ID Application: ..." identity (or "-" for ad-hoc) to sign the bundle.
SIGN_IDENTITY :=
CODESIGN_FLAGS := --options runtime --timestamp
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
TEST_BIN := $(BUILD_DIR)/tests/CLITickerTests
ICON := Assets/AppIcon/CLITicker.icns
SOURCES := $(wildcard Sources/CLITickerObjC/*.m)
HEADERS := $(wildcard Sources/CLITickerObjC/*.h)

.PHONY: all run test previews dist clean

all: $(BIN)

$(ICON): scripts/generate_icon_assets.py
	python3 scripts/generate_icon_assets.py
	iconutil -c icns Assets/AppIcon/CLITicker.iconset -o "$(ICON)"

$(BIN): $(SOURCES) $(HEADERS) $(ICON) Assets/CLIRegistry/registry.json
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	mkdir -p "$(APP_DIR)/Contents/Resources/Logos"
	cp -R Assets/Logos/. "$(APP_DIR)/Contents/Resources/Logos/"
	cp "$(ICON)" "$(APP_DIR)/Contents/Resources/CLITicker.icns"
	cp Assets/AppIcon/CLIStatusTemplate.png "$(APP_DIR)/Contents/Resources/CLIStatusTemplate.png"
	rm -rf "$(APP_DIR)/Contents/Resources/CLIRegistry"
	cp -R Assets/CLIRegistry "$(APP_DIR)/Contents/Resources/CLIRegistry"
	clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreServices $(SOURCES) -o "$(BIN)"
	printf '%s\n' \
	'<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0">' \
	'<dict>' \
	'  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	'  <key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' \
	'  <key>CFBundleName</key><string>$(DISPLAY_NAME)</string>' \
	'  <key>CFBundlePackageType</key><string>APPL</string>' \
	'  <key>CFBundleIconFile</key><string>CLITicker</string>' \
	'  <key>CFBundleVersion</key><string>$(VERSION)</string>' \
	'  <key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
	'  <key>LSUIElement</key><true/>' \
	'</dict>' \
	'</plist>' > "$(APP_DIR)/Contents/Info.plist"
	if [ -n "$(SIGN_IDENTITY)" ]; then codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" "$(APP_DIR)"; fi

run: all
	open "$(APP_DIR)"

previews: all
	"$(BIN)" --render-previews "$(BUILD_DIR)/previews"

# The test file #imports main.m, so link every other source alongside it.
$(TEST_BIN): Tests/CLITickerTests.m $(SOURCES) $(HEADERS)
	mkdir -p "$(dir $(TEST_BIN))"
	clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreServices "$<" $(filter-out %/main.m,$(SOURCES)) -o "$(TEST_BIN)"

test: $(TEST_BIN)
	"$(TEST_BIN)"

dist: all
	mkdir -p "$(BUILD_DIR)/dist"
	rm -f "$(BUILD_DIR)/dist/$(APP_NAME).app.tar.gz"
	tar -C "$(BUILD_DIR)" -czf "$(BUILD_DIR)/dist/$(APP_NAME).app.tar.gz" "$(APP_NAME).app"

clean:
	rm -rf "$(BUILD_DIR)"
