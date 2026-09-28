#!/usr/bin/env bash
# Installs the latest CLI release into ~/Applications and launches it:
#   curl -fsSL https://raw.githubusercontent.com/Malgsx/cli-ticker/main/install.sh | bash
set -euo pipefail

REPO="${CLI_TICKER_REPO:-Malgsx/cli-ticker}"
APP_NAME="CLITicker"
INSTALL_DIR="${CLI_TICKER_INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"
ASSET_URL="https://github.com/$REPO/releases/latest/download/$APP_NAME.app.tar.gz"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "CLI is a macOS app; this installer only runs on macOS."
command -v curl >/dev/null || fail "curl is required."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Downloading $ASSET_URL"
curl -fsSL "$ASSET_URL" -o "$tmpdir/$APP_NAME.app.tar.gz" \
  || fail "could not download the latest release from github.com/$REPO."
tar -xzf "$tmpdir/$APP_NAME.app.tar.gz" -C "$tmpdir"
[[ -x "$tmpdir/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]] || fail "the release archive does not contain $APP_NAME.app."

if pgrep -xq "$APP_NAME"; then
  echo "Quitting the running copy of CLI"
  pkill -x "$APP_NAME" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq "$APP_NAME" || break; sleep 0.5; done
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_PATH"
ditto "$tmpdir/$APP_NAME.app" "$APP_PATH"

# Release builds are not notarized, so Gatekeeper would block a quarantined copy.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "Installed CLI $version to $APP_PATH"

if [[ "${CLI_TICKER_NO_LAUNCH:-}" != "1" ]]; then
  open "$APP_PATH"
  echo "CLI is running. Look for its icon in the menu bar."
fi
