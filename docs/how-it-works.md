# How LimitBar works

The internals behind the [README](../README.md): the CLI contract, caching, how each provider is read, and how the menu bar and widget lay out readings.

Three pieces ship in one bundle:

- `LimitBar.app` collects usage directly and renders the menu-bar UI.
- `LimitBar.app/Contents/Helpers/limitbar` exposes the same service as schema-v1 JSON for scripts and agents.
- `LimitBarWidgetExtension.appex` reads only a sanitized display snapshot.

The app is intentionally unsandboxed because it must launch the user's `codex` and `claude` executables. The widget extension is sandboxed.

## CLI contract

The default command immediately reuses each provider's cache entry when it is no more than 300 seconds old, then refreshes only stale providers:

```bash
limitbar --json
limitbar --json --provider codex
limitbar --json --provider claude
limitbar --json --cache-only
limitbar --json --refresh
limitbar --json --max-age 300
limitbar --json --no-cache
```

Additional compatible options are `--compact`, `--timeout SECONDS`, repeatable `--provider`, `--codex-home PATH`, `--claude-home PATH`, `--include-spend`, and `--version`.

- Exit `0`: every requested reading is fresh and usable.
- Exit `1`: at least one reading failed, is partial, or is stale.
- Exit `2`: invalid arguments.

Every data invocation emits one complete schema-v1 JSON document. Unknown values remain `null`; they are never coerced to healthy or exhausted. Billing/spend is opt-in, is never cached, and is never included in the widget snapshot.

`--refresh` ignores freshness but honors an active provider cooldown. `--cache-only` makes no provider calls and marks returned data stale. `--no-cache` is a diagnostic live request that reads and writes neither snapshot nor cooldown state.

## Shared cache and cooldowns

The app and CLI share:

```text
~/Library/Caches/limitbar/snapshot.json
~/Library/Caches/limitbar/refresh-state.json
~/Library/Caches/limitbar/refresh.lock
```

The JSON files and lock are mode `0600`; writes are atomic. A cross-process `flock` covers the freshness decision and live refresh, so rapid app/agent polls collapse into one upstream call per freshness window.

Provider failures are independent. When a live refresh fails, the current failure status and error remain visible while last-good values are retained with `stale: true`. Claude `429` responses honor `Retry-After`; otherwise cooldown grows from 15 minutes to one hour and resets after a success.

## Provider behavior

Codex launches `codex app-server --listen stdio://`, completes `initialize`, calls `account/rateLimits/read`, drains stdout and stderr concurrently, and terminates then kills a child that does not exit. Codex owns its OAuth state; LimitBar never reads it.

Codex discovery supports `CODEX_BINARY`, PATH, Homebrew, user-local installations, fnm, and nvm. For fnm, it checks the default alias before installed Node versions, including custom `FNM_DIR`/`XDG_DATA_HOME` and standard macOS locations. The selected executable's directory is prepended to the child PATH so npm launchers can find their matching Node even when the app opens from Finder or at login.

Claude credentials are read only, and nothing in LimitBar ever puts a Keychain dialog on screen. Lookup is `/usr/bin/security find-generic-password` (killed after five seconds), then `~/.claude/.credentials.json`, then `CLAUDE_CODE_OAUTH_TOKEN`. The app never queries the Keychain in-process.

Why: `Claude Code-credentials` is a legacy login-keychain item whose ACL Claude Code rewrites every time it rotates the token. Any grant this app earns, "Always Allow" included, is revoked within hours, and the next in-process read asks for the login password again. That was the recurring password dialog. Claude Code writes the item through `security`, which keeps that tool on the ACL across rotations, so reading through it is silent. CodexBar reached the same conclusion and stopped reading the item by default (its issues #2380 and #3798).

**Keeping the login alive.** Only Claude Code refreshes its Keychain token, and only while it runs. Someone who works in the Claude desktop app (which gives its sessions a separate token) can go days without starting the terminal CLI, and the Keychain token lapses after about eight hours. The old design then showed a cached reading forever, however often Refresh was clicked. Now, when the Keychain token is expired or within five minutes of it, LimitBar starts the user's own `claude` in a hidden pseudo-terminal from `~/Library/Application Support/LimitBar/ClaudeProbe`, with `--strict-mcp-config` and hooks disabled. Claude Code refreshes its login on startup. LimitBar watches the item's modification date (an attribute read that never touches the secret), stops `claude`, and reads the new token. Inherited `CLAUDE_CODE_*` and `ANTHROPIC_*` variables are stripped from the child so it signs in from the Keychain like a terminal session would. The probe's session transcripts are deleted afterwards.

A `401`/`403` re-reads the Keychain once, then renews through `claude` and retries.

**Fallback: `/usage`.** If no token can be read or renewed, the same hidden session types `/usage` and parses the "Current session" and "Current week (…)" percentages (source `claude-cli-usage`; reset times are left unknown). As of 2026-10-19 (Claude Code 2.1.302) the `/usage` panel was showing "Failed to load usage data" during testing, so this path is wired and unit-tested against captured screens but is the least proven source.

**Throttle.** Background polls launch `claude` at most once per 15 minutes across the app and the CLI (marker file `~/Library/Caches/limitbar/claude-cli-launch`), and at most once per fetch. The popover's **Refresh** button is not throttled. Right-click, wake and popover-open refreshes are.

A Keychain-sourced credential is cached in memory until one minute before the `expiresAt` it carries.

`weekly_scoped` limits are a separate weekly cap on one model or surface, on top of the all-models weekly; the window is named from its `scope` (for example `Fable 7d`). Its allowance is a share of the all-models weekly (`weekly_scoped_shares`, 50% for Fable on Pro), so model usage counts against both.

Claude checks the live OAuth profile, then requests usage unless the profile confirms a free account. Both requests use ephemeral HTTPS to the allow-listed Anthropic host. Cross-host or non-HTTPS redirects are rejected and HTTP error bodies are discarded.

## Menu bar

A live Claude OAuth profile reporting `claude_free` automatically hides Claude from the menu bar, popover, and widget. The CLI reports `no_subscription` and clears previously cached quota. Providers with missing credentials or an unavailable CLI are also hidden on all three display surfaces. Expired credentials, blocked Keychain access, missing subscription metadata, and temporary network failures remain visible. If no providers are configured, the menu bar shows `AI` and the popover explains how to connect one. Refreshes continue checking both providers so newly configured providers appear automatically. CLI JSON still includes every requested provider and its diagnostic status. Normal refreshes recheck the live profile so Claude returns after resubscribing. Pro, Max, Team, Enterprise, and unknown profiles remain visible.

The status item is one column per provider, and subscribed Claude Code owns the first column:

```text
Cl 3h 57%   Cx 6d 83%
   6d 97%
```

The provider code labels its column from the strip's vertical centre, with the readings in a block to its right. The first row is always the five-hour session window; the second is the provider's tightest longer bucket. Both are led by their *countdown to reset* rather than a label — row position already says which window it is, so the label slot buys a more useful number. The window's real name survives in the tooltip.

A row names its window instead — `5h` — only when it has no reset time to count down from, since `?` in the label slot would say strictly less while the percentage is still worth reading. The same label stands in when the five-hour row has no window at all to describe.

A row the provider has no window for is left blank, and a column holding a single reading centres it rather than stranding it on the lower half. Codex reports no five-hour bucket, so its weekly sits beside its code on one line — which says "Codex has one window" more honestly than a placeholder would.

Every glyph is the same font, size and colour. The one exception is a reading that is running out, because that is the thing uniformity cannot express:

| Remaining | Colour |
| --- | --- |
| 30% and above | label colour |
| below 30% | yellow (amber on light backgrounds, where `systemYellow` is illegible at this size) |
| below 15% | orange |
| below 5% | red |

Unknown values stay grey, and one cache mark (`·`) per column marks a reading served from the CLI's last-good snapshot. `UsageSeverity` owns this ramp, so the popover and widget grade the same number the same way.

The app polls every five minutes, refreshes five seconds after the Mac wakes, and refreshes when the popover opens on numbers more than two minutes old.

## Widget

After every app refresh, `WidgetSnapshot` projects the full document down to display-only strings, integers, statuses, and reset dates. It writes mode-`0600` atomic snapshots to the existing ad-hoc-compatible app and widget-container locations. The widget target depends only on `LimitBarDomain`; it cannot read credentials or call providers.

The menu bar and widget preserve the pinned Claude five-hour contract: only a genuine 300-minute/five-hour window can occupy that cell. A missing window is shown as missing rather than borrowing a weekly or monthly value.

The medium and large families give **every window its own row** — label, gauge, remaining percent, and its own countdown to reset — with Claude first and the five-hour session above the weekly:

```text
LimitBar

Cl   5h ▓▓▓▓▓▓▓▓░  90%   ↻ 4h
     7d ▓▓▓▓▓▓▓▓░  92%   ↻ 6d

Cx   7d ▓▓▓▓▓▓░░░  75%   ↻ 6d
```

Each window resets on its own clock — the session several times a day, the weekly once — so the countdown belongs per row rather than once per provider. The gauge carries the full `UsageSeverity` ramp (green / yellow / orange / red); the percentage stays plain while healthy and tints only at warning and critical, because yellow text on a light widget background is close to unreadable. The small family has room for one number, so it shows whichever window across both providers is closest to exhaustion.

A macOS 26 note: WidgetKit will not load an extension whose entry point is `main`. `scripts/build-app.sh` links the `.appex` with `-e _NSExtensionMain`, which is what Xcode's app-extension product type does and what supplies the blocking XPC runloop. Without it the process returns from `main` immediately and the widget never appears in the gallery — registered, never loaded, nothing in the log.

## Verification

```bash
swift build --disable-sandbox
swift test --disable-sandbox
scripts/verify-security.sh
```

Swift Testing covers schema normalization, malformed payloads, free-plan 30-day classification, Claude legacy/current windows, redirects, status handling, cache freshness, cache-only behavior, file permissions, and canary token exclusion. Provider clients, clocks, transports, credentials, and cache directories are injected; tests use no real credentials or network.

The security verifier also statically asserts that only the credential reader touches the Keychain (and only through `/usr/bin/security`), only `ClaudeProvider` references the permitted host, and only `ClaudeProvider` unwraps a `Secret`.
