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
- **Claude multi-account support** — follows the active Claude Code account and preserves known profiles
- **Codex usage tracking** — shows OpenAI Codex session and weekly plan-limit windows
- **CLI sync** — picks up Claude Code `/login` credentials and Codex CLI login state
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

1. Open cliMeter — it appears in your menu bar
2. For Claude usage, run `/login` in Claude Code
3. For Codex usage, run `codex login`
4. cliMeter detects the credentials automatically

That's it. No API keys to paste, no config files to edit.

## Security

- Claude credentials are read from Claude Code's macOS Keychain item
- Claude Code-synced tokens are kept in memory only; cliMeter stores non-secret account metadata locally
- Codex credentials are read from the Codex CLI auth file managed by `codex login`
- cliMeter never refreshes or writes Claude Code's shared OAuth token
- No data leaves your machine except provider API calls to Anthropic and OpenAI/ChatGPT usage endpoints
- No analytics, no telemetry, no tracking
- Open source — read every line

## How it works

cliMeter reads the OAuth credentials that Claude Code stores in the system Keychain for Claude usage. It uses the short-lived access token and re-reads the Keychain when needed; it does not refresh or overwrite Claude Code's token. For Codex usage, it reads the current Codex CLI OAuth login from `$CODEX_HOME/auth.json` or `~/.codex/auth.json`. It polls provider usage endpoints every 3 minutes and displays the result.

You can toggle each provider on or off in Settings.

Codex usage is displayed separately and does not participate in Claude profile detection.

## Requirements

- macOS 14 (Sonoma) or later
- Claude Code CLI with an active Claude Pro/Team/Enterprise subscription for Claude usage
- Codex CLI with a ChatGPT/Codex plan for Codex usage

## License

MIT
