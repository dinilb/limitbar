#!/usr/bin/env bash
# Install or remove LimitBar.
#
#   curl -fsSL https://raw.githubusercontent.com/dinilb/limitbar/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/dinilb/limitbar/main/scripts/install.sh | bash -s -- --uninstall
#
# Installs the latest GitHub release to ~/Applications/LimitBar.app. It checks the
# download's SHA-256, its code signature, the signing team and Apple notarisation
# before anything is replaced. No sudo, nothing outside your home folder.

set -euo pipefail

REPO="dinilb/limitbar"
# The Apple Developer team that signs releases. A download signed by anyone
# else is refused.
TEAM_ID=""
APP_NAME="LimitBar"
BUNDLE_ID="com.dinilb.LimitBar"
WIDGET_ID="com.dinilb.LimitBar.LimitBarWidgetExtension"
INSTALL_DIR="$HOME/Applications"

# Testing hooks: point at a different zip/checksum, or accept an unnotarised build.
ZIP_URL="${LIMITBAR_ZIP_URL:-https://github.com/$REPO/releases/latest/download/LimitBar.zip}"
SHA_URL="${LIMITBAR_SHA_URL:-$ZIP_URL.sha256}"
ALLOW_UNNOTARIZED="${LIMITBAR_ALLOW_UNNOTARIZED:-0}"

info() { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$1" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

quit_app() {
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    info "Quitting the running $APP_NAME"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
      sleep 0.5
    done
    pkill -x "$APP_NAME" 2>/dev/null || true
  fi
}

uninstall() {
  quit_app
  local removed=0
  for dir in "$INSTALL_DIR" /Applications; do
    if [[ -d "$dir/$APP_NAME.app" ]]; then
      if rm -rf "$dir/$APP_NAME.app"; then
        info "Removed $dir/$APP_NAME.app"
        removed=1
      else
        warn "could not remove $dir/$APP_NAME.app"
      fi
    fi
  done
  [[ $removed -eq 1 ]] || info "$APP_NAME.app was not installed"

  local link="$HOME/.local/bin/limitbar"
  if [[ -L "$link" && "$(readlink "$link")" == *"/$APP_NAME.app/"* ]]; then
    rm -f "$link" && info "Removed $link"
  fi

  rm -rf "$HOME/Library/Caches/limitbar" "$HOME/Library/Application Support/$APP_NAME"
  rm -rf "$HOME/Library/Containers/$WIDGET_ID" 2>/dev/null \
    || warn "macOS kept the widget's container at ~/Library/Containers/$WIDGET_ID; it holds only a display snapshot"
  info "Removed caches and widget data. Your Claude Code and Codex logins were not touched."
  info "If you added LimitBar as a Login Item, remove it in System Settings › General › Login Items."
}

install() {
  [[ "$(uname -s)" == "Darwin" ]] || die "LimitBar is a macOS app"
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [[ "$major" -ge 14 ]] || die "LimitBar needs macOS 14 or newer (this Mac has $(sw_vers -productVersion))"
  [[ "$(uname -m)" == "arm64" ]] || die "release builds are Apple silicon only; build from source on Intel: https://github.com/$REPO#build-it-yourself"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  info "Downloading $APP_NAME"
  curl -fsSL --proto '=https,file' "$ZIP_URL" -o "$tmp/LimitBar.zip" || die "download failed: $ZIP_URL"
  curl -fsSL --proto '=https,file' "$SHA_URL" -o "$tmp/LimitBar.zip.sha256" || die "checksum download failed: $SHA_URL"

  local expected actual
  expected="$(awk '{ print $1; exit }' "$tmp/LimitBar.zip.sha256")"
  actual="$(shasum -a 256 "$tmp/LimitBar.zip" | awk '{ print $1 }')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || die "checksum mismatch; refusing to install"
  info "Checksum OK"

  ditto -x -k "$tmp/LimitBar.zip" "$tmp/unpacked"
  local app="$tmp/unpacked/$APP_NAME.app"
  [[ -d "$app" ]] || die "the download does not contain $APP_NAME.app"

  codesign --verify --deep --strict "$app" 2>/dev/null || die "code signature is invalid; refusing to install"
  local bundle team
  bundle="$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  [[ "$bundle" == "$BUNDLE_ID" ]] || die "unexpected bundle identifier '$bundle'; refusing to install"

  if [[ "$ALLOW_UNNOTARIZED" == "1" ]]; then
    warn "skipping the signing-team and notarisation checks (LIMITBAR_ALLOW_UNNOTARIZED=1)"
  else
    team="$(codesign -dv "$app" 2>&1 | awk -F= '/^TeamIdentifier/ { print $2 }')"
    if [[ -n "$TEAM_ID" ]]; then
      [[ "$team" == "$TEAM_ID" ]] || die "signed by team '$team', expected '$TEAM_ID'; refusing to install"
    fi
    spctl --assess --type execute "$app" 2>/dev/null \
      || die "macOS Gatekeeper rejected the app (not notarised?); refusing to install"
    info "Signature and notarisation OK (team $team)"
  fi

  quit_app
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  ditto "$app" "$INSTALL_DIR/$APP_NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 || true

  local version
  version="$(defaults read "$INSTALL_DIR/$APP_NAME.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
  info "Installed $APP_NAME $version to $INSTALL_DIR/$APP_NAME.app"
  open "$INSTALL_DIR/$APP_NAME.app"
  cat <<NEXT

LimitBar is now in your menu bar.
  - Command line tool: open the popover › terminal menu › Install Command Line Tool…
  - Start at login:    System Settings › General › Login Items › add LimitBar
  - Uninstall:         curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash -s -- --uninstall
NEXT
}

main() {
  case "${1:-}" in
    "") install ;;
    --uninstall) uninstall ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//' || true ;;
    *) die "unknown option: $1" ;;
  esac
}

# Everything runs from here, so a truncated download can't run half a script.
main "$@"
