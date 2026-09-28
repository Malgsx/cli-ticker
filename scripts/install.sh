#!/usr/bin/env bash
# Kept so older links to scripts/install.sh keep working; the installer lives at the repo root.
set -euo pipefail
repo="${CLI_TICKER_REPO:-Malgsx/cli-ticker}"
curl -fsSL "https://raw.githubusercontent.com/${repo}/main/install.sh" | CLI_TICKER_REPO="$repo" bash
