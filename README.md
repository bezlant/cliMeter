# cliMeter

macOS menu bar app that tracks Claude Code and OpenAI Codex usage in real time.

See session and weekly limits at a glance. Know when you're running low before you hit a wall.

[![GitHub release](https://img.shields.io/github/v/release/bezlant/cliMeter)](https://github.com/bezlant/cliMeter/releases/latest)
[![GitHub downloads](https://img.shields.io/github/downloads/bezlant/cliMeter/total)](https://github.com/bezlant/cliMeter/releases)
![macOS](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

![Climeter](screenshot.png)

## Why

Claude Code and Codex do not keep their usage limits visible while you work. You often find out when you're blocked. cliMeter fixes that with a tiny menu bar view that stays out of your way.

## Features

- **Menu bar progress bar** — color-coded (green/orange/red) so you know at a glance
- **Session + weekly tracking** — see both the 5-hour session and 7-day usage windows
- **Password-free Claude usage** — reads sanitized rate-limit data from Claude Code's status line
- **Keychain compatibility mode** — optional legacy multi-account support when explicitly selected
- **Codex usage tracking** — shows OpenAI Codex session and weekly plan-limit windows
- **Codex CLI sync** — picks up the Codex CLI login state automatically
- **Peak hours indicator** — shows when Claude rate limits are tighter (5–11 AM PT, weekdays) with countdown in your local timezone
- **Per-provider toggles** — show or hide Claude and Codex independently
- **Auto-update check** — notifies you when a new version is available

## Install

### Homebrew (recommended)

```bash
brew install bezlant/tap/climeter
```

### Manual download

Download `Climeter.zip` from [the latest release](https://github.com/bezlant/cliMeter/releases/latest), unzip, and drag `Climeter.app` to `/Applications`.

### Build from source

```bash
git clone git@github.com:bezlant/cliMeter.git
cd cliMeter
xcodebuild -scheme Climeter -configuration Release -derivedDataPath build
cp -R build/Build/Products/Release/Climeter.app /Applications/
```

## Update

```bash
brew upgrade climeter
```

New versions are published automatically — the Homebrew cask updates on every release.

## Setup

1. Open cliMeter — it appears in your menu bar.
2. Install the Claude usage exporter:

   ```bash
   mkdir -p "$HOME/Library/Application Support/Climeter"
   curl -fsSL \
     https://raw.githubusercontent.com/bezlant/cliMeter/v1.0.26/scripts/claude-usage-export.sh \
     -o "$HOME/Library/Application Support/Climeter/claude-usage-export.sh"
   chmod 700 "$HOME/Library/Application Support/Climeter/claude-usage-export.sh"
   ```

3. In your Claude Code status-line script, capture stdin once and pass the same
   JSON to the exporter:

   ```bash
   input=$(cat)
   printf '%s' "$input" |
     "$HOME/Library/Application Support/Climeter/claude-usage-export.sh" \
     >/dev/null 2>&1
   ```

   Keep your existing visible status-line output after this hook. Claude Code
   runs it after responses; cliMeter updates within a few seconds. If you do not
   have a status line yet, create a shell script with the snippet above and set
   it as Claude Code's `statusLine.command`.

4. For Codex usage, run `codex login`.

No Claude OAuth credential is read in the default mode. Settings includes an
explicit Keychain compatibility mode for legacy multi-account behavior.

## Security

- Claude usage defaults to an owner-only sanitized file containing only rate-limit percentages and reset times
- Claude OAuth credentials are not read unless Keychain compatibility mode is explicitly selected
- Compatibility-mode tokens are kept in memory only; cliMeter stores non-secret account metadata locally
- Codex credentials are read from the Codex CLI auth file managed by `codex login`
- cliMeter never refreshes or writes Claude Code's shared OAuth token
- No data leaves your machine except provider API calls to Anthropic and OpenAI/ChatGPT usage endpoints
- No analytics, no telemetry, no tracking
- Open source — read every line

## How it works

Claude Code sends its status-line JSON to a small local exporter. The exporter
allowlists only the two rate-limit windows, merges concurrent sessions under a
file lock, and atomically writes an owner-only snapshot for cliMeter. No Claude
OAuth credential is needed. Keychain compatibility mode retains the previous
read-only credential behavior when explicitly selected.

For Codex usage, cliMeter reads the current Codex CLI OAuth login from
`$CODEX_HOME/auth.json` or `~/.codex/auth.json` and polls the usage endpoint.

You can toggle each provider on or off in Settings.

Codex usage is displayed separately and does not participate in Claude profile detection.

## Requirements

- macOS 14 (Sonoma) or later
- Claude Code CLI with an active Claude Pro/Team/Enterprise subscription for Claude usage
- Codex CLI with a ChatGPT/Codex plan for Codex usage

## License

MIT
