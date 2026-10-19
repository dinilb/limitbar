# LimitBar

Your Claude Code and Codex limits, live in the macOS menu bar, plus a JSON CLI your agents can check before they start a big run.

<!-- TODO: screenshot or GIF of the menu bar + popover -->
![LimitBar in the menu bar](docs/screenshot.png)

```text
Cl 3h 57%   Cx 6d 83%
   6d 97%
```

Each column is one provider. The top row is the five-hour session, the bottom row is the tightest weekly limit. Each reading is the countdown to its reset, then what's left. The text turns yellow, orange and red as a limit runs low.

## What you get

- **Menu bar**: remaining % and time to reset for every Claude Code and Codex window.
- **Popover**: every window with its own gauge and reset time.
- **Widget**: small, medium and large WidgetKit widgets.
- **CLI for agents**: `limitbar --json` returns one stable, documented JSON document with exit codes, so a script or coding agent can decide whether to start work now or wait for a reset.

## Requirements

- macOS 14 or newer on Apple silicon (Intel Macs: [build it yourself](#build-it-yourself))
- At least one of:
  - [Claude Code](https://code.claude.com/docs) installed and signed in (run `claude` once)
  - [Codex CLI](https://github.com/openai/codex) installed and signed in (`codex login`)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dinilb/limitbar/main/scripts/install.sh | bash
```

This downloads the latest notarised release from GitHub Releases, checks its SHA-256 and Apple notarisation, and installs `LimitBar.app` to `~/Applications`. No sudo. Read [the script](scripts/install.sh) first if you like; it's short.

Or download `LimitBar.zip` from [Releases](https://github.com/dinilb/limitbar/releases), unzip, and drag `LimitBar.app` into Applications.

### Build it yourself

Don't want to run someone else's binary near your credentials? Fair. Building from source needs Xcode and takes about a minute:

```bash
git clone https://github.com/dinilb/limitbar.git
cd limitbar
scripts/verify-security.sh          # static checks + the test suite
scripts/build-app.sh --install --run
```

Or have your own agent audit it first. Paste this into Claude Code or Codex inside the clone:

> Audit this repository before I build it. List every file, Keychain item, environment variable and network host it reads or writes, every process it launches, and anything that could send my credentials or usage data off this machine. Quote the exact code for each.

### Command line tool

Open the popover, click the terminal menu, and choose **Install Command Line Tool…**. That creates `~/.local/bin/limitbar`, a symlink into the app bundle.

### Start at login

System Settings › General › Login Items › add LimitBar. Or:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'"$HOME"'/Applications/LimitBar.app", hidden:false}'
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/dinilb/limitbar/main/scripts/install.sh | bash -s -- --uninstall
```

That quits the app and removes the app, its caches, its widget data, and the `~/.local/bin/limitbar` symlink if it points at LimitBar. It doesn't touch your Claude Code or Codex logins. Remove the Login Item in System Settings if you added one.

## Privacy and security

Everything runs on your Mac. No telemetry, no analytics, no accounts, no auto-updater, no server of mine.

**What it reads**

- **Claude Code:** the access token Claude Code already stores, through `/usr/bin/security find-generic-password` (the `Claude Code-credentials` Keychain item), then `~/.claude/.credentials.json`, then `CLAUDE_CODE_OAUTH_TOKEN`. The app never queries the Keychain in-process, so it never shows a Keychain password dialog. The token is only held in memory, and only `ClaudeProvider.swift` can unwrap it.
- **Codex:** nothing. LimitBar runs your own `codex app-server` and asks it for rate limits. Codex keeps its own login; LimitBar never sees it.

**What it talks to**

- `https://api.anthropic.com/api/oauth/profile` and `/api/oauth/usage`, with your Claude token, over HTTPS. That's the only host in the code, and `scripts/verify-security.sh` fails the build if any other one shows up. Redirects to other hosts are refused.
- Codex makes its own requests to OpenAI. LimitBar only talks to the local `codex` process.

**What it launches**

- `codex app-server`, to read Codex limits.
- `claude`, hidden, only when Claude Code's stored login has expired (at most once every 15 minutes in the background). Starting `claude` makes Claude Code refresh its own login, which LimitBar then reads. It runs from `~/Library/Application Support/LimitBar/ClaudeProbe` with MCP servers and hooks turned off, sends no prompt, and its session files are deleted afterwards. If that doesn't work, it types `/usage` and reads the percentages off the screen.

**What it writes**

- `~/Library/Caches/limitbar/`: the last reading (percentages and reset times only) and refresh/cooldown state, mode `0600`. No tokens.
- `~/Library/Application Support/LimitBar/` and the widget's container: a display-only snapshot for the widget.
- `~/.local/bin/limitbar`, only if you ask for it.

Billing/spend data is only fetched with `--include-spend`, is never cached, and never reaches the widget.

## For agents and scripts

```bash
limitbar --json                     # cached if under 5 minutes old, else live
limitbar --json --provider claude
limitbar --json --cache-only        # no network
limitbar --json --refresh           # force a live read (respects cooldowns)
```

Exit codes: `0` every reading is fresh and usable, `1` something is failed, partial or stale (the JSON still prints), `2` bad arguments.

```json
{
  "schema_version": 1,
  "ok": true,
  "providers": [
    {
      "provider": "claude",
      "status": "ok",
      "stale": false,
      "windows": [
        {"key": "five_hour", "label": "5h", "remaining_percent": 73, "resets_at": "2026-08-07T21:00:00Z", "resets_in_seconds": 18000},
        {"key": "weekly", "label": "7d", "remaining_percent": 56, "resets_at": "2026-08-10T16:00:00Z", "resets_in_seconds": 259200}
      ]
    }
  ],
  "tightest": {"provider": "claude", "window_key": "weekly", "remaining_percent": 56, "resets_at": "2026-08-10T16:00:00Z"}
}
```

Unknown values are `null`, never guessed. A gate before an expensive run can be one line:

```bash
[ "$(limitbar --json | jq '.tightest.remaining_percent // 0')" -ge 20 ] || { echo "low on quota, waiting"; exit 1; }
```

The full contract, caching and provider details are in [docs/how-it-works.md](docs/how-it-works.md).

## How it compares

There are plenty of good tools in this space. Pick the one that fits:

| | LimitBar | [CodexBar](https://github.com/steipete/CodexBar) | [ClaudeBar](https://github.com/tddworks/ClaudeBar) | [Claudius](https://github.com/Abd-K/claudius-claude-code-usage) |
|---|---|---|---|---|
| Providers | Claude Code, Codex | 100+ | Claude, Codex, Gemini, Copilot, Cursor | Claude |
| Menu bar + widget | ✓ | ✓ | menu bar | menu bar |
| JSON CLI for agents | ✓ documented schema + exit codes | ✓ CLI | URL scheme | — |
| Size | ~4k lines of Swift, no dependencies | large | medium | small |

Features for the other tools are from their READMEs as of October 2026. If I've got something wrong, open an issue.

If you want every provider under the sun, use CodexBar; it's excellent. LimitBar is for people who only use Claude Code and Codex and want something small enough to read in one sitting, with a CLI their agents can rely on.

## Caveats

- Claude's usage endpoint is the one Claude Code itself uses, but it isn't publicly documented, so Anthropic can change it without notice. Codex's `app-server` protocol is the same story on OpenAI's side.
- Release builds are signed and notarised. Self-built ones are signed with whatever identity you have (or ad-hoc), and macOS may hide an ad-hoc-signed widget from the gallery.
- Not affiliated with Anthropic or OpenAI. Claude and Codex are their trademarks.

## Development

```bash
swift build --disable-sandbox
swift test --disable-sandbox
scripts/verify-security.sh
scripts/build-app.sh            # assemble build/LimitBar.app
```

```text
Sources/
  LimitBarDomain/      schema-v1 model, menu bar and widget presentation
  LimitBarProviders/   Claude and Codex providers, credentials, cache, cooldowns
  LimitBarMenuBar/     the menu bar app
  LimitBarCLI/         the bundled `limitbar` JSON CLI
  LimitBarWidget/      sandboxed WidgetKit extension
Tests/
docs/                  how it works, design notes, original research
scripts/               build, release, install, security checks
```

Issues and PRs welcome. Run `scripts/verify-security.sh` before opening one.

## License

[MIT](LICENSE)
