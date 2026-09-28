#!/usr/bin/env bash
# Exercises bin/cli without downloading a release or opening the app.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cli="$root/bin/cli"

run() {
  env CLI_TICKER_DRY_RUN=1 CLI_TICKER_REPO=Malgsx/cli-ticker "$@"
}

out="$(run CLI_TICKER_INSTALLED_VERSION=0.3.0 CLI_TICKER_LATEST_VERSION=0.4.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "Updating CLI 0.3.0 to 0.4.0."
printf '%s\n' "$out" | grep -q "dry-run: would install 0.4.0"

out="$(run CLI_TICKER_INSTALLED_VERSION= CLI_TICKER_LATEST_VERSION=0.4.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "Updating CLI to 0.4.0."

out="$(run CLI_TICKER_INSTALLED_VERSION=0.4.0 CLI_TICKER_LATEST_VERSION=0.4.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "CLI 0.4.0 is up to date"
printf '%s\n' "$out" | grep -q "dry-run: would relaunch"

out="$(run CLI_TICKER_INSTALLED_VERSION=0.10.0 CLI_TICKER_LATEST_VERSION=0.3.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "up to date"
if printf '%s\n' "$out" | grep -q "Updating CLI"; then
  echo "a newer local build must not reinstall an older release" >&2
  exit 1
fi

out="$(run CLI_TICKER_INSTALLED_VERSION=0.3.0 CLI_TICKER_LATEST_VERSION=0.10.0 "$cli" update)"
printf '%s\n' "$out" | grep -q "to 0.10.0"

out="$(CLI_TICKER_INSTALLED_VERSION=0.3.0 CLI_TICKER_LATEST_VERSION=0.9.0 "$cli" version)"
printf '%s\n' "$out" | grep -qx "CLI 0.3.0"
printf '%s\n' "$out" | grep -q "CLI 0.9.0 is available. Run cli update."

out="$(CLI_TICKER_INSTALLED_VERSION=1.2.0 CLI_TICKER_LATEST_VERSION=1.2.0 "$cli" version)"
printf '%s\n' "$out" | grep -qx "CLI 1.2.0"
if printf '%s\n' "$out" | grep -q "available"; then
  echo "an equal version must not be called an update" >&2
  exit 1
fi

out="$(run CLI_TICKER_INSTALLED_VERSION=0.3.0 "$cli" reload)"
printf '%s\n' "$out" | grep -q "dry-run: would relaunch"

"$cli" help | grep -q "cli update"
if "$cli" nope >/dev/null 2>&1; then
  echo "unknown commands should fail" >&2
  exit 1
fi

echo "cli command tests passed"
