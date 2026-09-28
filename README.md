# CLI

**Install (macOS)** — paste into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/Malgsx/cli-ticker/main/install.sh | bash
```

This downloads the latest release into `~/Applications`, clears the Gatekeeper quarantine flag, and opens the app. Look for the new icon in your menu bar. It also installs a `cli` command (`CLI` is the same command). The copy lives in `~/.local/bin`, and the installer links it into `/usr/local/bin` or `/opt/homebrew/bin` when that directory is writable, which a default macOS zsh already searches. If neither directory is writable, it adds `~/.local/bin` to `PATH` in `~/.zshrc`. Run `cli` to open the menu bar app.

## Update

`cli` and `CLI` are the same command.

Inside a clone of this repo, `cli update` pulls the latest code for your current branch (`git pull --ff-only`) and reinstalls the menu bar app from that checkout:

```sh
cli update
```

Without a clone, the same command installs the latest published GitHub release and opens it. Installing from a fork records that fork, so `cli update` installs the fork's release.

`cli` on its own opens the app you already have. `cli reload` quits it and opens it again. `cli version` prints the version and says when a newer release is out.

The menu bar app checks GitHub on launch and every six hours. When a release is newer than the installed app, it posts a notification and the panel footer says to run `CLI update`. A push becomes that update once it is published as a release. Inside a clone, `cli update` pulls source instead of installing that release.

## What it is

A native macOS menu bar app that finds every command-line tool on your Mac, groups your AI agent CLIs (Claude Code, Codex, Cursor Agent, Gemini, Aider, and others), and shows which ones have updates. You can update any of them with one click.

The first time it opens (the installer opens it for you), it scans your Mac and shows "Scanning your machine…" in the panel, then lists only what you actually have. It looks at `PATH`, Homebrew formulae and casks, npm and Bun globals, uv and pipx tools, `cargo install`, Go binaries, `~/.local/bin`, and CLIs bundled inside apps in `/Applications`. Tools it has no entry for still appear, with a generic icon. Later launches open instantly from the saved results and rescan in the background. Use the rescan button (⌘R) in the panel to scan again. The download button opens Update all in its own movable window, ten commands to a page, with Exit at the top of the card, instead of a system dialog. Closing that window cancels, and the menu-bar panel can close without dismissing it. The ☰ button (or right-clicking the menu bar icon) opens the menu: update all, rescan, select, the app version (click to update when a newer release exists), settings (terminal, rescan interval, launch at login, show or hide agents), the report, and About.

Click a row, or press Return, to open that CLI in your preferred terminal (Settings → preferred terminal: Terminal, Ghostty, iTerm, Warp, or Alacritty). The choice is saved, and the launch is aimed at that app's bundle id. Agents such as Claude and Codex launch as-is. Other CLIs run with `--help`, unless their registry entry sets `open` to different arguments. If that terminal isn't installed, the panel says so and only then opens Terminal.app. The `↑ update` button on a row is a separate click and only updates.

**Select** in the toolbar or the menu (⌘S) puts a checkbox on each row. Click to toggle, shift-click a range, or press ⌘A to select everything that can be removed. The footer reads "N selected · Uninstall". Uninstall always opens a confirmation sheet that lists each CLI and the exact command (`brew uninstall`, `brew uninstall --cask`, `npm uninstall -g`, `pipx uninstall`, `uv tool uninstall`, `cargo uninstall`, removing a Go binary, `gh extension remove`, and the same idea for Bun). Nothing is removed until you confirm. Apple’s own tools and CLIs bundled inside apps stay unchecked, with a reason. Confirmed uninstalls run one at a time, show a result on each row, then rescan.

**Privacy:** nothing about your machine is hardcoded in the app or uploaded anywhere. The scan results are saved only in `~/Library/Application Support/CLITicker`. There is no account and no telemetry. The only network traffic is version lookups: the package managers' own `outdated` commands, and anonymous requests to the public GitHub releases API for tools whose latest version is published there, and for CLI itself.

![CLI menu bar panel](docs/screenshot.png)

## Build from source / fork

Needs the Xcode Command Line Tools (`xcode-select --install`). Run this in any folder:

```sh
git clone https://github.com/Malgsx/cli-ticker.git && cd cli-ticker && ./cli run
```

To make it your own, click **Fork** at the top of this page, then clone your fork the same way, replacing `Malgsx` with your GitHub username. `./cli run` builds `build/CLITicker.app` and opens it. Every project command goes through `./cli`:

```sh
./cli help       # list all commands
./cli build      # build build/CLITicker.app
./cli run        # build, then open the app
./cli test       # run the unit tests
./cli install    # build and install to ~/Applications, then launch it
./cli update     # pull this checkout and reinstall the app from it
./cli uninstall  # quit and remove the installed app and its saved data
./cli version    # print the version (from the VERSION file)
```

See [docs/customizing.md](docs/customizing.md) to add CLIs, change logos, rename the app, sign it, and publish your own releases.

## Uninstall

From a clone, run `./cli uninstall`. Without a clone, paste this into Terminal:

```sh
pkill -x CLITicker
rm -rf ~/Applications/CLITicker.app ~/Library/Application\ Support/CLITicker
for f in ~/.local/bin/cli /usr/local/bin/CLI /usr/local/bin/cli /opt/homebrew/bin/CLI /opt/homebrew/bin/cli; do
  if [ -L "$f" ] && grep -q cli-ticker-command "$f" 2>/dev/null; then rm -f "$f"; fi
done
if [ -f ~/.local/bin/CLI ] && grep -q cli-ticker-command ~/.local/bin/CLI 2>/dev/null; then rm -f ~/.local/bin/CLI ~/.local/bin/cli-ticker-repo; fi
if [ -f ~/.local/bin/cli ] && grep -q cli-ticker-command ~/.local/bin/cli 2>/dev/null; then rm -f ~/.local/bin/cli; fi
if [ -f ~/.zshrc ] && grep -q cli-ticker-command ~/.zshrc; then grep -v cli-ticker-command ~/.zshrc > ~/.zshrc.cli-ticker && mv ~/.zshrc.cli-ticker ~/.zshrc; fi
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

Tell the user to look for the CLI icon in the menu bar and click it, or to run `cli` (or `CLI`) in Terminal to open the panel. Inside a clone, `cli update` pulls the latest source and reinstalls the app from that checkout. With no clone, `CLI update` installs the latest published release and opens the app. `CLI reload` quits it and opens it again. `CLI version` prints the version and says when a newer release is out. To install without launching the app, set `CLI_TICKER_NO_LAUNCH=1` for the `bash` side of the pipe (`... | CLI_TICKER_NO_LAUNCH=1 bash`). To build from source instead, run the clone command in [Build from source / fork](#build-from-source--fork) from the user's current directory. It needs `xcode-select -p` to succeed first. Inside the clone, use `./cli <command>` for everything (`./cli help` lists them): `./cli install` puts the source build in `~/Applications` and launches it, `./cli update` pulls and reinstalls from that checkout, `./cli test` runs the tests, and `./cli uninstall` removes the app and its data.

## More

- [Customizing, packaging, and how scanning works](docs/customizing.md)
- [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT License](LICENSE)
