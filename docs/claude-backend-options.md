# Claude backend: what's broken and the options (2026-10-19)

Status: options 1 (A) and 2 (B) built 2026-10-19; see README "How it reads your usage". Option D (statusline) and C (own login) not built.

## What's actually happening (checked on this Mac, 2026-10-19)

1. **The Keychain read already works silently.** `limitbar --json --no-cache --provider claude`
   returned in 0.05s with no dialog. `/usr/bin/security` is on the item's ACL with status OK.
2. **The token inside it is dead.** `Claude Code-credentials` holds an access token that expired
   about 16 hours before this check. Result: `auth_expired`, and the menu bar
   falls back to the cached last-good reading. That's the "it keeps caching" part.
3. **Nothing refreshes that token.** The developer's Claude Code sessions mostly run inside the desktop app,
   which injects `CLAUDE_CODE_OAUTH_TOKEN` into each session. Only the terminal `claude` CLI
   refreshes the Keychain item, and only while it's running. The widget refuses to refresh
   tokens itself (by design, see README), so it just sits on an expired token.
4. **"Always Allow" can never stick.** The item's ACL still lists `LimitBar.app`, but with an error
   status: the grant is pinned to an old ad-hoc build's cdhash. Also, every token rotation by
   Claude Code rewrites the ACL. CodexBar's source says the same thing ("any permission granted
   to CodexBar is inherently temporary and can cause recurring macOS password dialogs"), and
   their issue #3798 confirms it. So any path that prompts, prompts again on the next rotation.
   That's the password dialog loop.
5. No code-signing identity on this Mac (`security find-identity` finds 0), so every rebuild also
   gets a new identity in Keychain's eyes.

**Bottom line:** the current design depends on someone else's token that nobody keeps fresh, and
on a Keychain grant that can't survive. Patching the read path again won't fix that.

## How CodexBar (steipete) does it (v0.77.0, read from source)

- Claude source order in Auto: **OAuth API → `claude` CLI in a PTY (`/usage`) → claude.ai web cookies.**
- It stopped reading `Claude Code-credentials` by default in v0.47.0 (issue #2380). Now that read is
  an opt-in setting that's off by default. Without consent it falls through to the PTY, where
  `claude` reads its own item with no prompt (and refreshes the token as a side effect).
- It caches credentials in **its own Keychain item** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
  plus a 30 min in-memory cache. Its own item never prompts because it created it.
- Prompt policy setting: Never / Only on user action (default) / Always. A denial backs off for 6h.
- PTY probe: `claude --allowed-tools "" --strict-mcp-config --settings '{"disableAllHooks":true,...}'`
  run from a dedicated folder, sends `/usage`, parses "Current session" / "Current week", then
  deletes that folder's `.jsonl` files. Background CLI spawns are throttled to one per 15 min.
- Adaptive refresh: 2 min if the menu was opened recently, up to 30 min when idle or on low power.
- Local JSONL logs are used for cost estimates only, never for quota %.

## Options

### A. Let `claude` keep its own token fresh (smallest change)
Keep today's silent `security` read. When the token is expired (or within ~10 min of expiring),
spawn a headless `claude` run, throttled to once per 15 min, so Claude Code refreshes its own
Keychain item. Then re-read it.
- Pros: about a day's work. Zero prompts, since only `security` and `claude` touch the item. Same
  OAuth endpoint and same numbers as today.
- Cons: depends on the CLI. Spawning `claude` is slow (seconds). Need the cheapest command that
  forces a refresh without spending tokens (to test: `/usage` via PTY, `claude auth status`, etc).

### B. Make the CLI's `/usage` the Claude source (the CodexBar fallback)
Run `claude` in a PTY, send `/usage`, parse the result. No token handling at all.
- Pros: never touches credentials. Can't prompt. Survives any change to how Claude Code stores tokens.
- Cons: screen-scraping breaks when Claude Code changes its UI wording. Slower. Needs a PTY harness.
  Best as a fallback behind A, not on its own.

### C. Our own login ("Sign in with Claude" in the app)
The app runs its own OAuth PKCE flow once and stores **its own** refresh token in its own Keychain
item. It refreshes itself and never reads Claude Code's item.
- Pros: cleanest architecture. Fully independent of the CLI and desktop app. Zero prompts forever.
- Cons: it would have to reuse Claude Code's OAuth client ID, which is a terms/grey-area risk
  (uncertain; Anthropic has cracked down on third-party use of Claude Code OAuth). One-time login
  in a browser. The most code (PKCE, callback, refresh, rotation).

### D. Statusline feed (free bonus source)
A custom `~/.claude/statusline.sh` can write a small limits file (5h and 7d used % and reset
times) from the `rate_limits` JSON that Claude Code pipes in. The widget could read that file as
a zero-cost source whenever it's fresher than the last API reading.
- Pros: trivial to add, zero auth, real numbers.
- Cons: only updates while a *terminal* CLI session is active. Desktop-app sessions don't run the
  statusline, so it goes stale quickly. A bonus source only.

### E. claude.ai web cookies
Skip. It needs the Chrome or Claude Safe Storage key, which is another foreign Keychain item that
prompts, so it would recreate the same problem.

## Recommendation

**A + B + D in one source chain:** statusline file (if fresh) → silent Keychain read via `security`
→ if expired, let `claude` refresh itself (throttled) and re-read → PTY `/usage` as a last resort.
Also:
- Delete the in-process interactive Keychain path completely. It's the only thing that can draw
  the password dialog, and the grant it earns dies on the next rotation anyway.
- Add CodexBar-style adaptive refresh.

Keep C as a later option if the CLI dependency becomes painful and the terms question is settled.
