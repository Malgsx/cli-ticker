# CLI

**Install (macOS)** — paste into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/Malgsx/cli-ticker/main/install.sh | bash
```

This downloads the latest release into `~/Applications`, clears the Gatekeeper quarantine flag, and opens the app. Look for the new icon in your menu bar.

## What it is

A native macOS menu bar app that finds every command-line tool on your Mac (Homebrew, npm, Bun, uv, `PATH`), groups your AI agent CLIs, and shows which ones have updates. You can update any of them with one click. Everything stays local: no account and no telemetry.

![CLI menu bar panel](docs/screenshot.png)

## Build from source / fork

Needs the Xcode Command Line Tools (`xcode-select --install`). Run this in any folder:

```sh
git clone https://github.com/Malgsx/cli-ticker.git && cd cli-ticker && ./cli run
```

To make it your own, click **Fork** at the top of this page, then clone your fork the same way, replacing `Malgsx` with your GitHub username. `./cli run` builds `build/CLITicker.app` and opens it. See [docs/customizing.md](docs/customizing.md) to add CLIs, change logos, rename the app, sign it, and publish your own releases.

## Uninstall

```sh
pkill -x CLITicker; rm -rf ~/Applications/CLITicker.app ~/Library/Application\ Support/CLITicker
```

## For AI agents

To install CLI on the user's Mac, run these steps in order. Stop and report the error output if any step fails.

1. Check that you are on macOS. This command must print `Darwin`:

   ```sh
   uname -s
   ```

2. Install. The command quits any running copy, installs to `~/Applications/CLITicker.app`, and launches it:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/Malgsx/cli-ticker/main/install.sh | bash
   ```

   On success, the output ends with `Installed CLI <version> to /Users/<user>/Applications/CLITicker.app` and `CLI is running.`

3. Verify. This command must print `ok` and a process ID:

   ```sh
   test -x ~/Applications/CLITicker.app/Contents/MacOS/CLITicker && pgrep -x CLITicker && echo ok
   ```

Tell the user to look for the CLI icon in the menu bar and click it. To install without launching the app, set `CLI_TICKER_NO_LAUNCH=1` for the `bash` side of the pipe (`... | CLI_TICKER_NO_LAUNCH=1 bash`). To build from source instead, run the clone command in [Build from source / fork](#build-from-source--fork) from the user's current directory. It needs `xcode-select -p` to succeed first.

## More

- [Customizing, packaging, and how scanning works](docs/customizing.md)
- [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT License](LICENSE)
