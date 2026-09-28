# CLI

CLI is a native macOS menu bar app for tracking command-line tools installed on a machine. It scans local package managers and executable paths, groups known AI agent CLIs, and shows available updates without requiring an account.

It is a few Objective-C/AppKit source files plus a `Makefile`, so it is meant to be forked and made your own.

![CLI icon](Assets/AppIcon/CLITickerIcon-1024.png)

## Features

- Icon-only menu bar app. Clicking the icon opens a compact, keyboard-friendly panel (dark slate, monospace, Omarchy-style) with `CLIs`, `Agents`, `Updates`, `Recent`, and `All` views, inline search, a preferred-terminal picker, and per-source bar charts. Right-click (or control-click) the icon for the classic menu below.
- `CLIs` view: well-known CLIs (gh, git, node, npm, brew, docker, kubectl, terraform, aws, gcloud, az, firebase, vercel, stripe, cursor, claude, and more) with a monochrome logo, installed version, how it was installed, and whether it is up to date. When an update is available the row's `↑ update` button runs the matching command in the background (for example `brew upgrade gh`, `npm install -g firebase-tools`, `gcloud components update --quiet`, `gh extension upgrade --all`), shows live progress and the result, then re-checks the version. Updates only ever run from that click.
- `Agent Tools` submenu for tools like Codex, Notion, Antigravity, Claude, Amp, Cora, Cursor, Goose, OpenCode, CodeRabbit, Kisuke, Droid, and related CLIs. Clicking one opens it in your preferred terminal.
- `Search CLIs` opens a native search panel for installed tools.
- `Updates Available` submenu with readable version changes, clickable update actions, and an `Update All` action that runs every supported update in one terminal session. Updated tools drop off the list after the rescan that follows.
- `Recently Updated` submenu that fills in automatically when a CLI is installed or updated on the machine.
- `Open Report` submenu for JSON or Markdown inventory reports.
- `Preferred Terminal` submenu with Terminal, Ghostty, iTerm, or Warp when installed.

## Download & Install

CLI requires macOS. Pick one of the options below.

### Option 1: Download a release (no build tools needed)

Download `CLITicker.app.tar.gz` from [GitHub Releases](https://github.com/Malgsx/cli-ticker/releases/latest), then:

```sh
mkdir -p ~/Applications
tar -xzf ~/Downloads/CLITicker.app.tar.gz -C ~/Applications
open ~/Applications/CLITicker.app
```

Or do it all in one command:

```sh
mkdir -p ~/Applications && curl -fL https://github.com/Malgsx/cli-ticker/releases/latest/download/CLITicker.app.tar.gz | tar -xz -C ~/Applications && open ~/Applications/CLITicker.app
```

### Option 2: Installer script

The script finds the newest release, installs it to `~/Applications`, and clears the Gatekeeper quarantine flag:

```sh
curl -fsSL https://raw.githubusercontent.com/Malgsx/cli-ticker/main/scripts/install.sh | bash
open ~/Applications/CLITicker.app
```

`scripts/install.sh` honors two environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLI_TICKER_REPO` | `Malgsx/cli-ticker` | `owner/repo` to download releases from (point it at your fork) |
| `CLI_TICKER_INSTALL_DIR` | `~/Applications` | Where `CLITicker.app` is installed |

### Option 3: Build from source

```sh
git clone https://github.com/Malgsx/cli-ticker.git
cd cli-ticker
./cli run
```

This needs the Xcode Command Line Tools (`xcode-select --install`). See [Fork & Customize](#fork--customize) for details.

### Opening an unsigned app (Gatekeeper)

Release builds are not yet signed or notarized. macOS may say the app "can't be opened because Apple cannot check it for malicious software". To allow it, do one of the following:

- In Finder, right-click (or Control-click) `CLITicker.app` in `~/Applications`, choose **Open**, then click **Open** in the dialog. You only need to do this once.
- Or remove the quarantine flag from Terminal:

  ```sh
  xattr -dr com.apple.quarantine ~/Applications/CLITicker.app
  ```

- On recent macOS versions, you can also go to **System Settings → Privacy & Security** and click **Open Anyway** after the first blocked launch.

Apps built locally from source are not quarantined, so they open normally.

### Uninstall

Quit CLI from its menu, then:

```sh
rm -rf ~/Applications/CLITicker.app ~/Library/Application\ Support/CLITicker
```

## Fork & Customize

### Prerequisites

- macOS (the app uses AppKit and FSEvents).
- Xcode Command Line Tools (`xcode-select --install`) for `clang`, `iconutil`, `plutil`, and `codesign`.
- Python 3 with Pillow (`python3 -m pip install pillow`). This is only needed when regenerating icons, which `make` does if `scripts/generate_icon_assets.py` is newer than the committed `.icns`.

### Clone, Build, Run

```sh
git clone https://github.com/<your-username>/cli-ticker.git ~/path/to/cli-ticker
cd ~/path/to/cli-ticker
./cli build   # same as `make`; produces build/CLITicker.app
./cli run     # builds, then opens the app
./cli clean   # removes build/
```

The first refresh can take a while because Homebrew and npm update checks shell out to local package managers. All paths in the build are relative to the repository root, so the clone can live anywhere.

### Project Layout

- `Sources/CLITickerObjC/main.m`: the app core. `InventoryService` scans package managers, and `MenuController` owns the menu, reports, and terminal launching.
- `Sources/CLITickerObjC/TickerPanel.m`: renders the menu bar panel.
- `Sources/CLITickerObjC/CLIRegistry.m`: detects registry CLIs, checks for updates, and runs updates with streamed progress.
- `Sources/CLITickerObjC/PanelPreview.m`: `make previews` renders the panel with fixture data to `build/previews/*.png`; CI uploads them as the `panel-previews` artifact.
- `Assets/CLIRegistry/registry.json`: the data-driven list of known CLIs: binaries, version parsing, Homebrew/npm package names, self-update commands, update checks, and GitHub release repos. Add an entry to support a new CLI.
- `Assets/CLIRegistry/icons/`: monochrome template icons from [Simple Icons](https://simpleicons.org) (CC0; brand marks remain their owners' trademarks). `scripts/fetch_cli_icons.py` regenerates them. Brands that Simple Icons no longer carries use a monogram.
- `Assets/Logos/`: PNG logos for agent tools, copied into the app bundle's `Resources/Logos`.
- `Assets/AppIcon/`: app icon, iconset, and the menu bar template image.
- `scripts/generate_icon_assets.py`: regenerates the app and menu bar icons.
- `Makefile`: builds, signs (optional), and packages the app.
- `cli`: small wrapper around the `make` targets.
- `.github/workflows/`: macOS build + smoke test on every push, and release publishing on `v*` tags.

### Add Or Remove Tracked Agent CLIs

Every CLI on `PATH` or in a supported package manager shows up in the inventory automatically. The `Agent Tools` submenu is a curated list. All of it lives near the top of `main.m`:

1. **`PreferredAgentOrder()`**: add or remove the tool's canonical name. The canonical name is usually its executable. This list controls both which tools count as agent tools and their menu order.
2. **`PackageAliases()`**: map package or install names to the canonical name, for example `@anthropic-ai/claude-code` → `claude`.
3. **`AgentBrandMetadata()`**: set the display `label`, plus the fallback `mark` (1–2 characters) and `color` used when there is no logo.
4. **`AgentInvocationName()`**: only needed when the command you type differs from the canonical name, for example `antigravity` → `agy`.
5. Optional: **`sourcePriorityForItem:canonicalName:`** picks which install wins when a tool is found in several places, and **`updateCommandForItem:`** adds a custom update command, such as a vendor `curl | bash` installer.

To remove a tool, delete its entries from those same places, and delete its logo if nothing else uses it.

### Add Or Change Logos

1. Drop a square PNG (roughly 64×64 or larger, transparent background) into `Assets/Logos/`, for example `Assets/Logos/mytool.png`.
2. In `AgentIcon()` in `main.m`, map the canonical name to the file name without the extension: `@"mytool": @"mytool"`.
3. Rebuild. The `Makefile` copies everything in `Assets/Logos/` into the bundle.

Tools without a logo get a generated rounded badge from `AgentBrandMetadata()`.

To restyle the app icon or the menu bar icon, edit `scripts/generate_icon_assets.py`, then `rm Assets/AppIcon/CLITicker.icns && make`. You can also replace the PNGs in `Assets/AppIcon/` directly.

### Change App Name, Bundle ID, And Version

The bundle identity is set by `Makefile` variables. Override them on the command line, or edit the defaults at the top of the `Makefile`:

```sh
make clean
make BUNDLE_ID=com.<your-username>.cli DISPLAY_NAME="My CLI" VERSION=1.0.0
```

| Variable | Default | Becomes |
| --- | --- | --- |
| `BUNDLE_ID` | `local.codex.cliticker` | `CFBundleIdentifier` (also scopes saved preferences) |
| `DISPLAY_NAME` | `CLI` | `CFBundleName` |
| `VERSION` | `0.1.1` | `CFBundleVersion` / `CFBundleShortVersionString` |
| `APP_NAME` | `CLITicker` | `.app` bundle and executable name |

If you change `APP_NAME`, also update the paths that expect `CLITicker.app` in `.github/workflows/*.yml` and `scripts/install.sh`.

Changing variables does not trigger a rebuild, so run `make clean` first. User-visible strings, such as menu titles and the `CLITicker` folder name under Application Support, are in `main.m`.

### Signing And Notarization

The build is unsigned unless you pass a signing identity:

```sh
# Ad-hoc signature (local use only)
make clean && make SIGN_IDENTITY=- CODESIGN_FLAGS=

# Developer ID signature with hardened runtime + secure timestamp (the defaults)
make clean && make SIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)"
```

To notarize the signed build:

```sh
ditto -c -k --keepParent build/CLITicker.app build/CLITicker.zip
xcrun notarytool submit build/CLITicker.zip --keychain-profile <your-notary-profile> --wait
xcrun stapler staple build/CLITicker.app
```

Unsigned or un-notarized downloads are quarantined by Gatekeeper. `scripts/install.sh` clears the quarantine flag for that reason.

### Packaging And Releases

```sh
./cli dist   # same as `make dist`; accepts the same variables as `make`
```

This produces `build/dist/CLITicker.app.tar.gz`.

To publish from your fork, push a version tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The Release workflow builds the archive on a macOS runner and attaches it to a GitHub release. The workflow does not sign, so add a signing and notarization step with your own secrets before promoting releases broadly.

To make the installer one-liner pull from your fork, change the `REPO` default at the top of `scripts/install.sh` to `<your-username>/cli-ticker`, or set `CLI_TICKER_REPO` when you run it.

## How Scanning Works

CLI scans:

- Non-system executable directories in `PATH`.
- Homebrew formulas and casks, including outdated status.
- Global npm packages and npm outdated status.
- Bun globals.
- uv tools.

Additional scanners go in `-[InventoryService refresh]`. Each scanner returns items built with `Item(...)`.

Reports are written locally to `~/Library/Application Support/CLITicker/`:

- `inventory.json`: the full inventory.
- `inventory.md`: a human-readable report.
- `changes.json`: recent install and update events.

### Automatic Change Detection

CLI uses FSEvents to watch common install locations: Homebrew `bin`/`Cellar`/`Caskroom`, `~/.local/bin`, `~/.bun/bin`, `~/.npm-global/bin`, and similar. The list is `CommonBinDirectories()` plus `installWatchPaths` in `main.m`. When a CLI is installed or updated through the app, a package manager, or a `curl | bash` installer, a debounced rescan runs a few seconds later. The rescan:

- moves the tool out of `Updates Available` once it is current, and
- records the change in `Recently Updated`, with the version transition (for example `0.1.0 → 0.2.0`) and how long ago it happened.

Recently Updated entries expire after 24 hours and are also written to the Markdown report. As fallbacks, a full scan runs every 15 minutes, and a refresh runs after each in-app update.

### CLI Update Checks

Checks run in the background and are cached, so opening the panel is instant:

- Installed versions are cached per binary (path + modification time) in `~/Library/Application Support/CLITicker/cli-versions.json`, so a version probe reruns only when a binary changes.
- Homebrew and npm installs use the inventory scan (`brew outdated`, `npm outdated -g`).
- Self-updating tools use a registry `check` command (for example `gcloud components list`) or the latest GitHub release, cached for 6 hours in `github-releases.json`.
- System binaries (such as `/usr/bin/git`) are shown as `system` and are never updated.

## Privacy

CLI stores inventory reports locally only. It shells out to locally installed package managers to read versions and update availability. Homebrew auto-update and analytics are disabled for app-launched Homebrew commands. The `CLIs` view also reads public GitHub release metadata for registry tools that have no local update check.

There is no remote account, telemetry endpoint, or server sync. Any future remote adapters should be opt-in and clearly documented.

## Ideas For Forks

- Remote release feeds (GitHub Releases, npm registry metadata, Homebrew livecheck, vendor RSS). Items already carry `currentVersion`, `latestVersion`, `source`, `path`, and `status`, so feeds can merge into the same model.
- More package managers (pipx, cargo, gem, mise, asdf).
- A first-run explanation of what is scanned and where reports are saved.

## Contributing

Issues and pull requests are welcome at [Malgsx/cli-ticker](https://github.com/Malgsx/cli-ticker).

1. Fork the repo and create a branch.
2. Make your change and check that `./cli build` succeeds. CI builds and launch-tests every push on a macOS runner.
3. Open a pull request that describes what changed and why.

Please keep scanning local-first and privacy-preserving by default. Treat changes to shell command construction carefully (see [SECURITY.md](SECURITY.md)). More notes are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Released under the [MIT License](LICENSE).
