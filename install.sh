#!/usr/bin/env bash
# Installs the latest CLI release into ~/Applications and launches it:
#   curl -fsSL https://raw.githubusercontent.com/Malgsx/cli-ticker/main/install.sh | bash
set -euo pipefail

REPO="${CLI_TICKER_REPO:-Malgsx/cli-ticker}"
APP_NAME="CLITicker"
INSTALL_DIR="${CLI_TICKER_INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"
ASSET_URL="${CLI_TICKER_ASSET_URL:-https://github.com/$REPO/releases/latest/download/$APP_NAME.app.tar.gz}"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "CLI is a macOS app; this installer only runs on macOS."
command -v curl >/dev/null || fail "curl is required."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if [[ -n "${CLI_TICKER_ARCHIVE:-}" ]]; then
  [[ -f "$CLI_TICKER_ARCHIVE" ]] || fail "$CLI_TICKER_ARCHIVE does not exist."
  echo "Using $CLI_TICKER_ARCHIVE"
  cp "$CLI_TICKER_ARCHIVE" "$tmpdir/$APP_NAME.app.tar.gz"
else
  echo "Downloading $ASSET_URL"
  curl -fsSL "$ASSET_URL" -o "$tmpdir/$APP_NAME.app.tar.gz" \
    || fail "could not download $ASSET_URL."
fi
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

# `cli update` is the user-facing command, like `claude update`. The script lives in
# the repo as bin/cli; a piped installer downloads that same file.
install_cli_command() {
  local dest="${CLI_TICKER_BIN_DIR:-$HOME/.local/bin}/cli"
  local src=""
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$here/bin/cli" ]]; then src="$here/bin/cli"; fi
  fi
  mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" ]] && ! grep -q cli-ticker-command "$dest" 2>/dev/null; then
    echo "warning: $dest already exists and is not the CLI command, so it was left alone." >&2
    echo "Move that file, run this installer again, and then use cli update." >&2
    return 0
  fi
  if [[ -n "$src" ]]; then
    cp "$src" "$dest"
  else
    local url="${CLI_TICKER_COMMAND_URL:-https://raw.githubusercontent.com/${REPO}/main/bin/cli}"
    echo "Downloading $url"
    curl -fsSL "$url" -o "$dest" || fail "could not download the cli command."
  fi
  chmod +x "$dest"

  local linked=""
  local dir
  for dir in /usr/local/bin /opt/homebrew/bin; do
    [[ -d "$dir" && -w "$dir" ]] || continue
    local link="$dir/cli"
    if [[ -L "$link" ]]; then
      local target
      target="$(readlink "$link")"
      # Replace only a link we created. Leave someone else's `cli` alone.
      if [[ "$target" != "$dest" ]] && ! grep -q cli-ticker-command "$target" 2>/dev/null; then
        continue
      fi
      rm -f "$link"
    elif [[ -e "$link" ]]; then
      continue
    fi
    ln -s "$dest" "$link"
    linked="$link"
    break
  done

  if [[ -z "$linked" ]] && ! printf '%s' ":${PATH:-}:" | grep -q ":$(dirname "$dest"):"; then
    local rc="$HOME/.zshrc"
    touch "$rc"
    if ! grep -q cli-ticker-command "$rc" 2>/dev/null; then
      printf '\nexport PATH="%s:$PATH" # cli-ticker-command\n' "$(dirname "$dest")" >> "$rc"
    fi
    echo "Open a new terminal, then run: cli update"
  else
    echo "Later, run cli update to install a newer release."
  fi
}
install_cli_command

if [[ "${CLI_TICKER_NO_LAUNCH:-}" != "1" ]]; then
  # Opening the app is what starts the first scan of this Mac; there is no separate step.
  first_launch=0
  [[ -e "$HOME/Library/Application Support/$APP_NAME/inventory.json" ]] || first_launch=1
  open "$APP_PATH"
  echo "CLI is running. Look for its icon in the menu bar."
  if [[ "$first_launch" == "1" ]]; then
    echo "First launch: CLI is scanning this Mac for installed CLIs and AI agents. The results stay on this Mac."
  fi
fi
