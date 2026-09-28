#!/usr/bin/env bash
# Kept so older links to scripts/install.sh keep working; the installer lives at the repo root.
set -euo pipefail
curl -fsSL "https://raw.githubusercontent.com/${CLI_TICKER_REPO:-Malgsx/cli-ticker}/main/install.sh" | bash
