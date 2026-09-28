# `./cli <command>` is the front door; it runs the targets below.
# Override any of these on the command line, e.g. `./cli build BUNDLE_ID=com.example.cli`.
# Changing them does not trigger a rebuild; run `./cli clean` first.
APP_NAME := CLITicker
DISPLAY_NAME := CLI
BUNDLE_ID := local.codex.cliticker
# The VERSION file is the only place the version is written down. Releases require the tag to match it.
VERSION := $(shell cat VERSION)
# GitHub repo the app checks for its own releases and links to from About.
REPO := Malgsx/cli-ticker
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
REGISTRY_ASSETS := Assets/CLIRegistry/registry.json Assets/CLIRegistry/icons $(wildcard Assets/CLIRegistry/icons/*)

INSTALL_DIR := $(HOME)/Applications

.PHONY: all run test previews dist install uninstall clean icons version help

all: $(BIN)

# The committed .icns is used as-is so a fresh clone builds without Python/Pillow
# (git checkout mtimes are arbitrary). Run `./cli icons` after editing the generator.
$(ICON):
	$(MAKE) icons

icons:
	python3 scripts/generate_icon_assets.py
	iconutil -c icns Assets/AppIcon/CLITicker.iconset -o "$(ICON)"

$(BIN): $(SOURCES) $(HEADERS) $(ICON) $(REGISTRY_ASSETS) VERSION
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	mkdir -p "$(APP_DIR)/Contents/Resources/Logos"
	cp -R Assets/Logos/. "$(APP_DIR)/Contents/Resources/Logos/"
	cp "$(ICON)" "$(APP_DIR)/Contents/Resources/CLITicker.icns"
	cp Assets/AppIcon/CLIStatusTemplate.png "$(APP_DIR)/Contents/Resources/CLIStatusTemplate.png"
	rm -rf "$(APP_DIR)/Contents/Resources/CLIRegistry"
	cp -R Assets/CLIRegistry "$(APP_DIR)/Contents/Resources/CLIRegistry"
	clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreServices -framework ServiceManagement $(SOURCES) -o "$(BIN)"
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
	'  <key>CLITickerRepository</key><string>$(REPO)</string>' \
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
	clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreServices -framework ServiceManagement "$<" $(filter-out %/main.m,$(SOURCES)) -o "$(TEST_BIN)"

test: $(TEST_BIN)
	"$(TEST_BIN)"

dist: all
	mkdir -p "$(BUILD_DIR)/dist"
	rm -f "$(BUILD_DIR)/dist/$(APP_NAME).app.tar.gz"
	tar -C "$(BUILD_DIR)" -czf "$(BUILD_DIR)/dist/$(APP_NAME).app.tar.gz" "$(APP_NAME).app"

# Same steps as the curl installer (quit the running copy, clear quarantine, launch), from this build.
install: dist
	CLI_TICKER_ARCHIVE="$(BUILD_DIR)/dist/$(APP_NAME).app.tar.gz" CLI_TICKER_INSTALL_DIR="$(INSTALL_DIR)" bash install.sh

uninstall:
	pkill -x "$(APP_NAME)" || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app" "$(HOME)/Library/Application Support/$(APP_NAME)"
	for link in "$(HOME)/.local/bin/cli" /usr/local/bin/CLI /usr/local/bin/cli /opt/homebrew/bin/CLI /opt/homebrew/bin/cli; do \
	  if [ -L "$$link" ] && grep -q cli-ticker-command "$$link" 2>/dev/null; then rm -f "$$link"; fi; \
	done
	if [ -f "$(HOME)/.local/bin/CLI" ] && grep -q cli-ticker-command "$(HOME)/.local/bin/CLI" 2>/dev/null; then rm -f "$(HOME)/.local/bin/CLI" "$(HOME)/.local/bin/cli-ticker-repo"; fi
	if [ -f "$(HOME)/.local/bin/cli" ] || [ -L "$(HOME)/.local/bin/cli" ]; then \
	  if [ ! "$(HOME)/.local/bin/cli" -ef "$(HOME)/.local/bin/CLI" ] && grep -q cli-ticker-command "$(HOME)/.local/bin/cli" 2>/dev/null; then rm -f "$(HOME)/.local/bin/cli"; fi; \
	fi
	if [ -f "$(HOME)/.zshrc" ] && grep -q cli-ticker-command "$(HOME)/.zshrc"; then grep -v cli-ticker-command "$(HOME)/.zshrc" > "$(HOME)/.zshrc.cli-ticker" && mv "$(HOME)/.zshrc.cli-ticker" "$(HOME)/.zshrc"; fi

clean:
	rm -rf "$(BUILD_DIR)"

version:
	@echo "$(VERSION)"

help:
	@./cli help
