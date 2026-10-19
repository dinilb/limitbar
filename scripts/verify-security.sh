#!/usr/bin/env bash
# Static and executable security checks for the all-Swift product.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! swift --version >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS  %s\n' "$1"; }

# ripgrep is not on every machine. Map the handful of flags this script uses onto
# grep so the checks run anywhere rather than silently reporting nothing.
if ! command -v rg >/dev/null 2>&1; then
  rg() {
    local args=() include=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --glob) include="--include=$2"; shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    if [[ -n "$include" ]]; then
      grep -rE "$include" "${args[@]}"
    else
      grep -E "${args[@]}"
    fi
  }
fi

# The app never queries the Keychain itself. `Claude Code-credentials` is a legacy
# login-keychain item whose ACL Claude Code rewrites on every token rotation, so any
# grant this app earned was revoked within hours and the next in-process read put a
# password dialog on screen. Only `/usr/bin/security` (always on the item's ACL)
# and `claude` itself may touch it.
KEYCHAIN_HITS="$(rg -l 'SecItemCopyMatching|kSecClassGenericPassword|SecKeychain' Sources --glob '*.swift' || true)"
[[ -z "$KEYCHAIN_HITS" ]] || fail "in-process Keychain access is back: $KEYCHAIN_HITS"
pass "no in-process Keychain access"

CREDENTIALS_FILE="Sources/LimitBarProviders/ClaudeCredentials.swift"
SECURITY_TOOL_HITS="$(rg -l 'find-generic-password' Sources --glob '*.swift' || true)"
[[ "$SECURITY_TOOL_HITS" == "$CREDENTIALS_FILE" ]] \
  || fail "security tool is invoked outside ClaudeCredentials.swift: $SECURITY_TOOL_HITS"
rg -q 'timeout: 5' "$CREDENTIALS_FILE" \
  || fail "security tool reads are no longer time-limited"
pass "security tool runs only from ClaudeCredentials.swift, time-limited"

# Background polls may launch `claude` only through the throttle.
rg -q 'launch.claim\(\)' Sources/LimitBarProviders/ClaudeProvider.swift \
  || fail "claude launches are no longer gated"
pass "claude launches go through the throttle"

HOST_HITS="$(rg -l 'api\.anthropic\.com' Sources --glob '*.swift' || true)"
[[ "$HOST_HITS" == "Sources/LimitBarProviders/ClaudeProvider.swift" ]] \
  || fail "allowed host is referenced outside ClaudeProvider.swift: $HOST_HITS"
pass "only ClaudeProvider.swift references the allowed network host"

UNEXPECTED_URLS="$(rg -n -o 'https://[A-Za-z0-9._-]+' Sources --glob '*.swift' | rg -v 'api\.anthropic\.com' || true)"
[[ -z "$UNEXPECTED_URLS" ]] || fail "unexpected Swift HTTPS destination: $UNEXPECTED_URLS"
pass "no unexpected Swift HTTPS destination"

# POSIX class rather than \s, so the pattern means the same thing to grep and rg.
UNWRAP_HITS="$(rg -n '\.withValue[[:space:]]*\{' Sources --glob '*.swift' | rg -v 'ClaudeProvider\.swift' || true)"
[[ -z "$UNWRAP_HITS" ]] || fail "Secret is unwrapped outside ClaudeProvider.swift: $UNWRAP_HITS"
pass "only ClaudeProvider.swift unwraps the token"

swift build --disable-sandbox >/dev/null
pass "all Swift products build"

if swift test --disable-sandbox >/tmp/limitbar-swift-test.log 2>&1; then
  pass "Swift Testing suite passes"
elif rg -q "no such module 'Testing'" /tmp/limitbar-swift-test.log; then
  printf 'SKIP  Swift Testing requires full Xcode (current toolchain is Command Line Tools)\n'
else
  sed -n '1,160p' /tmp/limitbar-swift-test.log >&2
  fail "Swift Testing suite failed"
fi

CLI="$(swift build --disable-sandbox --show-bin-path)/limitbar"
OUTPUT="$($CLI --json --compact --cache-only --provider all || [[ $? -eq 1 ]])"
printf '%s' "$OUTPUT" | jq -e '.schema_version == 1 and (.providers | type == "array")' >/dev/null \
  || fail "CLI did not emit valid schema-v1 JSON"
pass "CLI emits one complete JSON document on a degraded result"

if [[ -f "$HOME/Library/Caches/limitbar/snapshot.json" ]]; then
  MODE="$(stat -f '%Lp' "$HOME/Library/Caches/limitbar/snapshot.json")"
  [[ "$MODE" == "600" ]] || fail "snapshot mode is $MODE, expected 600"
  pass "snapshot file mode is 0600"
fi
