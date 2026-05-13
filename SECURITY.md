# Security

CLI shells out to local package managers and scans executable paths. Treat changes to command construction and shell launching carefully.

## Reporting Issues

Open a GitHub issue for low-risk bugs. For sensitive issues, contact the maintainer privately before publishing details.

## Current Security Posture

- Inventory reports are written locally under `~/Library/Application Support/CLITicker`.
- Homebrew auto-update and analytics are disabled for app-launched Homebrew commands.
- No telemetry or hosted backend is included.
- Future remote API/feed integrations should be opt-in.
