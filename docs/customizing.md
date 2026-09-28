# Customizing CLI

CLI is a few Objective-C/AppKit files plus a `Makefile`, so you can fork it and make it your own. Every project command goes through the `./cli` script, which runs the matching `Makefile` target (`make <target>` still works if you prefer it).

## Build

Requirements: macOS and the Xcode Command Line Tools (`xcode-select --install`). You only need Python 3 with Pillow if you regenerate the icons.

```sh
./cli help       # list all commands
./cli build      # produces build/CLITicker.app
./cli run        # build, then open the app
./cli test       # unit tests
./cli previews   # render the panel with fixture data to build/previews/*.png
./cli dist       # build/dist/CLITicker.app.tar.gz
./cli install    # build, install to ~/Applications with install.sh, and launch
./cli uninstall  # quit and remove ~/Applications/CLITicker.app and its saved data
./cli icons      # regenerate the app icons (needs Pillow)
./cli clean      # remove build/
./cli version    # print the version from the VERSION file
```

Any command accepts `NAME=value` overrides of the `Makefile` variables below, for example `./cli build BUNDLE_ID=com.you.cli`. `./cli install INSTALL_DIR=/Applications` installs somewhere else.

All paths are relative to the repository root, so the clone can live anywhere.

## Project layout

- `Sources/CLITickerObjC/main.m`: the app core. `InventoryService` scans package managers, and `MenuController` owns the menu, reports, and terminal launching.
- `Sources/CLITickerObjC/TickerPanel.m`: the menu bar panel, including its in-panel ☰ menu and settings view (their items come from `panelMenuItems` / `panelSettings` in `main.m`). There is no native `NSMenu`; right-click on the menu bar icon opens the panel with the menu showing. `./cli build REPO=<you>/cli-ticker` points the app's own update check and About link at your fork.
- `Sources/CLITickerObjC/CLIRegistry.m`: registry CLI detection, update checks, and updates with streamed progress.
- `Assets/CLIRegistry/registry.json`: the data-driven list of known CLIs (binaries, version parsing, package names, update commands, GitHub release repos). Add an entry to support a new CLI. `Assets/CLIRegistry/icons/` holds [Simple Icons](https://simpleicons.org) templates, which you can regenerate with `scripts/fetch_cli_icons.py`.
- `Assets/Logos/`: PNG logos for agent tools.
- `Assets/AppIcon/`: app icon and menu bar template image. Edit `scripts/generate_icon_assets.py`, then run `./cli icons` (needs Pillow).
- `install.sh`: the one-line installer. `.github/workflows/`: CI (build, tests, and README install tests) and releases on `v*` tags.

## Agent tools list

Every CLI on `PATH` or in a supported install source appears automatically. `InventoryService` in `main.m` scans `PATH`, Homebrew formulae and casks, npm and Bun globals, `uv tool`, `pipx`, `cargo install --list`, Go's `bin` directories, `~/.local/bin`, and `Contents/Resources/{app/,}bin` / `Contents/SharedSupport/bin` inside apps in `/Applications` and `~/Applications`. On first launch (no `inventory.json` yet) the panel shows the scan's progress. The CLIs view lists registry entries first, then detected CLIs the registry does not know, with a generic icon. Registry results are cached in `registry-status.json` so later launches open instantly.

Executables whose name contains a token such as `agent`, `ai`, `llm`, or `gpt` (see `LooksLikeAgentName()`) are added to the end of the `Agents` view with a generic icon. The curated part of the `Agents` view is defined near the top of `main.m`:

1. `PreferredAgentOrder()`: canonical names (usually the executable) and their order.
2. `PackageAliases()`: package names mapped to canonical names, for example `@anthropic-ai/claude-code` → `claude`.
3. `AgentBrandMetadata()`: display label, plus the fallback mark and color used when there is no logo.
4. `AgentInvocationName()`: only needed when the command differs from the canonical name (`antigravity` → `agy`).
5. `AgentIcon()`: maps the canonical name to a PNG in `Assets/Logos/` (square, transparent, 64×64 or larger).

## App name, bundle ID, version

```sh
./cli clean && ./cli build BUNDLE_ID=com.<you>.cli DISPLAY_NAME="My CLI" VERSION=1.0.0
```

| Variable | Default | Becomes |
| --- | --- | --- |
| `BUNDLE_ID` | `local.codex.cliticker` | `CFBundleIdentifier` (also scopes saved preferences) |
| `DISPLAY_NAME` | `CLI` | `CFBundleName` |
| `VERSION` | the `VERSION` file | `CFBundleShortVersionString`, compared with the latest release by the in-app Version item |
| `APP_NAME` | `CLITicker` | `.app` and executable name. If you change it, also update `install.sh` and the workflows. |

## Signing and notarization

Builds are unsigned by default. The installer clears the quarantine flag for that reason.

```sh
./cli clean && ./cli build SIGN_IDENTITY=- CODESIGN_FLAGS=                                  # ad-hoc
./cli clean && ./cli build SIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)" # Developer ID
ditto -c -k --keepParent build/CLITicker.app build/CLITicker.zip
xcrun notarytool submit build/CLITicker.zip --keychain-profile <profile> --wait
xcrun stapler staple build/CLITicker.app
```

## Publishing releases from your fork

Bump the `VERSION` file, commit it, then tag that version:

```sh
printf '1.0.0\n' > VERSION && git commit -am "Release 1.0.0" && git push
git tag "v$(./cli version)" && git push origin "v$(./cli version)"
```

The Release workflow fails if the tag does not match `VERSION`. Otherwise it builds `CLITicker.app.tar.gz` and attaches it to a GitHub release. CI also fails when `VERSION` is behind the latest release, so a source build never reports itself as out of date. To install from your fork, pipe the installer from your fork's URL and set `CLI_TICKER_REPO` on the `bash` side of the pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/<you>/cli-ticker/main/install.sh | CLI_TICKER_REPO=<you>/cli-ticker bash
```

You can also change the `REPO` default in `install.sh`. `CLI_TICKER_INSTALL_DIR` changes the install folder (default `~/Applications`), and `CLI_TICKER_NO_LAUNCH=1` skips opening the app.

If a downloaded build is ever blocked by Gatekeeper, run `xattr -dr com.apple.quarantine ~/Applications/CLITicker.app`, or right-click the app, choose **Open**, then click **Open** in the dialog.

## How scanning works

CLI scans non-system `PATH` directories, Homebrew formulas and casks, global npm packages, Bun globals, and uv tools. Additional scanners go in `-[InventoryService refresh]`. FSEvents watches common install locations (`CommonBinDirectories()` and `installWatchPaths` in `main.m`), so installs and updates trigger a debounced rescan. A full scan also runs every 15 minutes.

Reports are written only to `~/Library/Application Support/CLITicker/`: `inventory.json`, `inventory.md`, `changes.json`, and caches (`cli-versions.json`, `github-releases.json`).

## Privacy

Everything runs locally. The app shells out to your installed package managers, and Homebrew auto-update and analytics are disabled for those calls. It also reads public GitHub release metadata for registry tools that have no local update check. There is no account, telemetry, or sync.
