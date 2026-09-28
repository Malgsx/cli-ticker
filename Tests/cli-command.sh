#!/usr/bin/env bash
# Exercises bin/cli without downloading a release or opening the app.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cli="$root/bin/cli"
outside="$(mktemp -d)"
trap 'rm -rf "$outside"' EXIT

run() {
  env CLI_TICKER_DRY_RUN=1 CLI_TICKER_REPO=Malgsx/cli-ticker "$@"
}

# Release updates are what `cli update` does outside a checkout. The tests
# themselves live in this repo, so run those from a directory that is not one.
out="$(cd "$outside" && run CLI_TICKER_INSTALLED_VERSION=0.3.0 CLI_TICKER_LATEST_VERSION=0.4.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "Updating CLI 0.3.0 to 0.4.0."
printf '%s\n' "$out" | grep -q "dry-run: would install 0.4.0"
if printf '%s\n' "$out" | grep -q "git pull"; then
  echo "update outside a checkout must install the release, not pull source" >&2
  exit 1
fi

out="$(cd "$outside" && run CLI_TICKER_INSTALLED_VERSION= CLI_TICKER_LATEST_VERSION=0.4.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "Updating CLI to 0.4.0."

out="$(cd "$outside" && run CLI_TICKER_INSTALLED_VERSION=0.4.0 CLI_TICKER_LATEST_VERSION=0.4.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "CLI 0.4.0 is up to date"
printf '%s\n' "$out" | grep -q "dry-run: would relaunch"

out="$(cd "$outside" && run CLI_TICKER_INSTALLED_VERSION=0.10.0 CLI_TICKER_LATEST_VERSION=0.3.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "up to date"
if printf '%s\n' "$out" | grep -q "Updating CLI"; then
  echo "a newer local build must not reinstall an older release" >&2
  exit 1
fi

out="$(cd "$outside" && run CLI_TICKER_INSTALLED_VERSION=0.3.0 CLI_TICKER_LATEST_VERSION=0.10.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "to 0.10.0"

out="$(CLI_TICKER_INSTALLED_VERSION=0.3.0 CLI_TICKER_LATEST_VERSION=0.9.0 "$cli" version)"
printf '%s\n' "$out" | grep -qx "CLI 0.3.0"
printf '%s\n' "$out" | grep -q "CLI 0.9.0 is available. Run CLI update."

out="$(CLI_TICKER_INSTALLED_VERSION=1.2.0 CLI_TICKER_LATEST_VERSION=1.2.0 "$cli" version)"
printf '%s\n' "$out" | grep -qx "CLI 1.2.0"
if printf '%s\n' "$out" | grep -q "available"; then
  echo "an equal version must not be called an update" >&2
  exit 1
fi

out="$(cd "$outside" && run CLI_TICKER_INSTALLED_VERSION=0.3.0 "$cli" reload)"
printf '%s\n' "$out" | grep -q "dry-run: would relaunch"

out="$(cd "$outside" && run "$cli")"
printf '%s\n' "$out" | grep -q "dry-run: would open"

"$cli" help | grep -q "CLI update"
"$cli" help | grep -q "Open the menu bar app"
if "$cli" nope >/dev/null 2>&1; then
  echo "unknown commands should fail" >&2
  exit 1
fi

# Inside this checkout, update pulls and reinstalls instead of fetching the release.
out="$(cd "$root" && run "$cli" update)"
printf '%s\n' "$out" | grep -q "dry-run: would git pull --ff-only in $root"
printf '%s\n' "$out" | grep -q "dry-run: would reinstall from $root"
if printf '%s\n' "$out" | grep -q "would install"; then
  echo "update inside a checkout must not install the published release" >&2
  exit 1
fi

out="$(cd "$root" && CLI_TICKER_DRY_RUN=1 ./cli update)"
printf '%s\n' "$out" | grep -q "dry-run: would git pull --ff-only in $root"
printf '%s\n' "$out" | grep -q "dry-run: would reinstall from $root"

# A subdirectory of the clone still updates that clone.
mkdir -p "$root/build/cli-command-subdir-test"
out="$(cd "$root/build/cli-command-subdir-test" && run "$cli" update)"
printf '%s\n' "$out" | grep -q "dry-run: would git pull --ff-only in $root"
rmdir "$root/build/cli-command-subdir-test" 2>/dev/null || true

# A real fast-forward pull against a local origin, with the rebuild stubbed out.
pull_tmp="$(mktemp -d)"
git -C "$pull_tmp" init -b main seed >/dev/null
git -C "$pull_tmp/seed" config user.email "test@example.com"
git -C "$pull_tmp/seed" config user.name "CLI Test"
mkdir -p "$pull_tmp/seed/bin"
cp "$cli" "$pull_tmp/seed/bin/cli"
printf 'seed\n' > "$pull_tmp/seed/README"
git -C "$pull_tmp/seed" add bin/cli README
git -C "$pull_tmp/seed" commit -m seed >/dev/null
git -C "$pull_tmp" init --bare -b main origin >/dev/null
git -C "$pull_tmp/seed" remote add origin "$pull_tmp/origin"
git -C "$pull_tmp/seed" push -u origin main >/dev/null
git -C "$pull_tmp" clone -b main origin clone >/dev/null
printf 'pulled\n' >> "$pull_tmp/seed/README"
git -C "$pull_tmp/seed" add README
git -C "$pull_tmp/seed" commit -m pulled >/dev/null
git -C "$pull_tmp/seed" push origin main >/dev/null
out="$(cd "$pull_tmp/clone" && CLI_TICKER_REINSTALL_CMD=true "$cli" update)"
printf '%s\n' "$out" | grep -q "Pulling the latest source in $pull_tmp/clone"
printf '%s\n' "$out" | grep -q "Reinstalling CLI from $pull_tmp/clone"
grep -q pulled "$pull_tmp/clone/README"
mkdir -p "$pull_tmp/clone/nested"
out="$(cd "$pull_tmp/clone/nested" && CLI_TICKER_DRY_RUN=1 "$cli" update)"
printf '%s\n' "$out" | grep -q "dry-run: would git pull --ff-only in $pull_tmp/clone"
rm -rf "$pull_tmp"

# Command names. The owned copy is ~/.local/bin/CLI. On a case-sensitive disk,
# `cli` is a symlink to it and both names are linked into a PATH directory.
# On a case-insensitive disk the two names are one inode (-ef); a hard link
# stands in for that here so the installer must not delete the file it wrote.
cmd_home="$(mktemp -d)"
cmd_path="$(mktemp -d)"
HOME="$cmd_home" CLI_TICKER_BIN_DIR="$cmd_home/.local/bin" CLI_TICKER_LINK_DIRS="$cmd_path" \
  CLI_TICKER_COMMAND_ONLY=1 bash "$root/install.sh" >/dev/null
test -x "$cmd_home/.local/bin/CLI"
grep -q cli-ticker-command "$cmd_home/.local/bin/CLI"
test -L "$cmd_home/.local/bin/cli"
test "$(readlink "$cmd_home/.local/bin/cli")" = "$cmd_home/.local/bin/CLI"
test -L "$cmd_path/CLI"
test -L "$cmd_path/cli"
test "$(readlink "$cmd_path/cli")" = "$cmd_home/.local/bin/CLI"
test "$(readlink "$cmd_path/CLI")" = "$cmd_home/.local/bin/CLI"
test ! -e "$cmd_home/.zshrc"
out="$(cd "$outside" && CLI_TICKER_DRY_RUN=1 CLI_TICKER_INSTALLED_VERSION=0.4.0 CLI_TICKER_LATEST_VERSION=0.4.0 "$cmd_path/cli" version)"
printf '%s\n' "$out" | grep -qx "CLI 0.4.0"
out="$(cd "$outside" && CLI_TICKER_DRY_RUN=1 CLI_TICKER_INSTALLED_VERSION=0.4.0 CLI_TICKER_LATEST_VERSION=0.4.0 "$cmd_path/CLI" version)"
printf '%s\n' "$out" | grep -qx "CLI 0.4.0"
grep -qx 'Malgsx/cli-ticker' "$cmd_home/.local/bin/cli-ticker-repo"

# A fork install records that repo. Later `cli update` uses it without the env var.
# CLI_TICKER_REPO still overrides the stamp.
fork_home="$(mktemp -d)"
fork_path="$(mktemp -d)"
HOME="$fork_home" CLI_TICKER_BIN_DIR="$fork_home/.local/bin" CLI_TICKER_LINK_DIRS="$fork_path" \
  CLI_TICKER_REPO=someone/cli-ticker CLI_TICKER_COMMAND_ONLY=1 bash "$root/install.sh" >/dev/null
grep -qx 'someone/cli-ticker' "$fork_home/.local/bin/cli-ticker-repo"
out="$(cd "$outside" && CLI_TICKER_DRY_RUN=1 CLI_TICKER_INSTALLED_VERSION=0.3.0 CLI_TICKER_LATEST_VERSION=0.4.0 "$fork_path/cli" update)"
printf '%s\n' "$out" | grep -q "dry-run: would install 0.4.0 from someone/cli-ticker"
out="$(cd "$outside" && CLI_TICKER_DRY_RUN=1 CLI_TICKER_REPO=other/cli-ticker CLI_TICKER_INSTALLED_VERSION=0.3.0 CLI_TICKER_LATEST_VERSION=0.4.0 "$fork_path/cli" update)"
printf '%s\n' "$out" | grep -q "dry-run: would install 0.4.0 from other/cli-ticker"
rm -rf "$fork_home" "$fork_path"

# Same inode for cli and CLI (case-insensitive APFS). Reinstalling must keep it.
ln -f "$cmd_home/.local/bin/CLI" "$cmd_home/.local/bin/cli-hard"
rm -f "$cmd_home/.local/bin/cli"
ln "$cmd_home/.local/bin/CLI" "$cmd_home/.local/bin/cli"
test "$cmd_home/.local/bin/cli" -ef "$cmd_home/.local/bin/CLI"
HOME="$cmd_home" CLI_TICKER_BIN_DIR="$cmd_home/.local/bin" CLI_TICKER_LINK_DIRS="$cmd_path" \
  CLI_TICKER_COMMAND_ONLY=1 bash "$root/install.sh" >/dev/null
test -f "$cmd_home/.local/bin/CLI"
test "$cmd_home/.local/bin/cli" -ef "$cmd_home/.local/bin/CLI"
grep -q cli-ticker-command "$cmd_home/.local/bin/CLI"
rm -f "$cmd_home/.local/bin/cli-hard"

# A foreign cli or CLI is not replaced. The free name still gets our command.
foreign="$(mktemp -d)"
foreign_home="$(mktemp -d)"
printf 'foreign-cli\n' > "$foreign/cli"
mkdir -p "$foreign_home/.local/bin"
printf 'foreign-owned\n' > "$foreign_home/.local/bin/CLI"
chmod +x "$foreign/cli" "$foreign_home/.local/bin/CLI"
err="$(HOME="$foreign_home" CLI_TICKER_BIN_DIR="$foreign_home/.local/bin" CLI_TICKER_LINK_DIRS="$foreign" \
  CLI_TICKER_COMMAND_ONLY=1 bash "$root/install.sh" 2>&1)" || {
  printf '%s\n' "$err" >&2
  exit 1
}
printf '%s\n' "$err" | grep -q "left alone"
grep -qx 'foreign-cli' "$foreign/cli"
# Owned name was foreign, so nothing was installed over it and no PATH link was added.
grep -qx 'foreign-owned' "$foreign_home/.local/bin/CLI"
test ! -e "$foreign/CLI"

# Foreign CLI on PATH, free cli name: link cli, leave CLI alone.
open_home="$(mktemp -d)"
open_path="$(mktemp -d)"
printf 'foreign-CLI\n' > "$open_path/CLI"
chmod +x "$open_path/CLI"
err="$(HOME="$open_home" CLI_TICKER_BIN_DIR="$open_home/.local/bin" CLI_TICKER_LINK_DIRS="$open_path" \
  CLI_TICKER_COMMAND_ONLY=1 bash "$root/install.sh" 2>&1)"
printf '%s\n' "$err" | grep -q "left alone"
grep -qx 'foreign-CLI' "$open_path/CLI"
test -L "$open_path/cli"
test "$(readlink "$open_path/cli")" = "$open_home/.local/bin/CLI"
grep -q cli-ticker-command "$open_home/.local/bin/CLI"

# Foreign cli on PATH, free CLI name: link CLI, leave cli alone.
other_home="$(mktemp -d)"
other_path="$(mktemp -d)"
printf 'foreign-cli\n' > "$other_path/cli"
chmod +x "$other_path/cli"
err="$(HOME="$other_home" CLI_TICKER_BIN_DIR="$other_home/.local/bin" CLI_TICKER_LINK_DIRS="$other_path" \
  CLI_TICKER_COMMAND_ONLY=1 bash "$root/install.sh" 2>&1)"
printf '%s\n' "$err" | grep -q "left alone"
grep -qx 'foreign-cli' "$other_path/cli"
test -L "$other_path/CLI"
test "$(readlink "$other_path/CLI")" = "$other_home/.local/bin/CLI"
test -L "$other_home/.local/bin/cli"
test "$(readlink "$other_home/.local/bin/cli")" = "$other_home/.local/bin/CLI"

# When no PATH directory is writable, ~/.zshrc gains the owned directory.
zsh_home="$(mktemp -d)"
missing="$zsh_home/no-such-bin"
HOME="$zsh_home" CLI_TICKER_BIN_DIR="$zsh_home/.local/bin" CLI_TICKER_LINK_DIRS="$missing" \
  CLI_TICKER_COMMAND_ONLY=1 bash "$root/install.sh" >/dev/null
grep -q 'export PATH="'"$zsh_home"'/.local/bin:$PATH" # cli-ticker-command' "$zsh_home/.zshrc"
# A second run does not add another line.
HOME="$zsh_home" CLI_TICKER_BIN_DIR="$zsh_home/.local/bin" CLI_TICKER_LINK_DIRS="$missing" \
  CLI_TICKER_COMMAND_ONLY=1 bash "$root/install.sh" >/dev/null
test "$(grep -c cli-ticker-command "$zsh_home/.zshrc")" = 1
test -L "$zsh_home/.local/bin/cli"
test -x "$zsh_home/.local/bin/CLI"

# A directory that exists but is not writable is skipped the same way.
locked_home="$(mktemp -d)"
locked="$locked_home/locked"
mkdir -p "$locked"
chmod a-w "$locked"
if [[ -w "$locked" ]]; then
  echo "could not make a non-writable directory; skipping that check" >&2
else
  HOME="$locked_home" CLI_TICKER_BIN_DIR="$locked_home/.local/bin" CLI_TICKER_LINK_DIRS="$locked" \
    CLI_TICKER_COMMAND_ONLY=1 bash "$root/install.sh" >/dev/null
  test ! -e "$locked/cli"
  test ! -e "$locked/CLI"
  grep -q cli-ticker-command "$locked_home/.zshrc"
  chmod u+w "$locked"
fi

rm -rf "$cmd_home" "$cmd_path" "$foreign" "$foreign_home" "$open_home" "$open_path" "$other_home" "$other_path" "$zsh_home" "$locked_home"

echo "cli command tests passed"
