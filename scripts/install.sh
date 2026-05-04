#!/usr/bin/env bash
set -euo pipefail

REPO="${CLI_TICKER_REPO:-Malgsx/cli-ticker}"
APP_NAME="CLITicker.app"
INSTALL_DIR="${CLI_TICKER_INSTALL_DIR:-$HOME/Applications}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v unzip >/dev/null || { echo "unzip is required" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Fetching latest CLI Ticker release from github.com/$REPO..."
api_url="https://api.github.com/repos/$REPO/releases/latest"
asset_url="$(curl -fsSL "$api_url" | /usr/bin/python3 -c '
import json, sys
release = json.load(sys.stdin)
for asset in release.get("assets", []):
    if asset.get("name") == "CLITicker.zip":
        print(asset["browser_download_url"])
        break
')"

if [[ -z "${asset_url:-}" ]]; then
  echo "Could not find CLITicker.zip on the latest release." >&2
  exit 1
fi

curl -fL "$asset_url" -o "$tmpdir/CLITicker.zip"
unzip -q "$tmpdir/CLITicker.zip" -d "$tmpdir"

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
ditto "$tmpdir/$APP_NAME" "$INSTALL_DIR/$APP_NAME"

echo "Installed $APP_NAME to $INSTALL_DIR"
echo "Open it with:"
echo "  open \"$INSTALL_DIR/$APP_NAME\""
