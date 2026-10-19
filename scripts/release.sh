#!/usr/bin/env bash
# Build, sign, notarise and staple LimitBar, then attach it to a DRAFT GitHub release.
#
#   scripts/release.sh 1.0.0
#
# Needs, once per Mac:
#   - a "Developer ID Application" certificate in the login keychain
#   - notarytool credentials saved under a keychain profile:
#       xcrun notarytool store-credentials limitbar-notary
#     (override the profile name with NOTARY_PROFILE=...)
#   - gh signed in with access to the repository
#
# Nothing is published: the release stays a draft until you publish it on GitHub.

set -euo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh X.Y.Z" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
APP="build/LimitBar.app"
DIST="dist"
ZIP="$DIST/LimitBar.zip"
PROFILE="${NOTARY_PROFILE:-limitbar-notary}"
TAG="v$VERSION"

info() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v gh >/dev/null || die "gh not found (brew install gh)"
[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean; commit first"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || die "no notarytool profile '$PROFILE'; run: xcrun notarytool store-credentials $PROFILE"

info "Running security checks and tests"
scripts/verify-security.sh

info "Building $TAG"
LIMITBAR_VERSION="$VERSION" scripts/build-app.sh --release

rm -rf "$DIST"
mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$ZIP"

info "Submitting to Apple for notarisation (usually a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

info "Stapling the ticket and re-zipping"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 LimitBar.zip > LimitBar.zip.sha256)

TEAM_ID="$(codesign -dv "$APP" 2>&1 | awk -F= '/^TeamIdentifier/ { print $2 }')"
info "Signed by team $TEAM_ID; make sure scripts/install.sh pins the same TEAM_ID"

info "Creating draft release $TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" \
  --draft \
  --target "$(git rev-parse HEAD)" \
  --title "LimitBar $VERSION" \
  --notes "Install: \`curl -fsSL https://raw.githubusercontent.com/dinilb/limitbar/main/scripts/install.sh | bash\`

Or download LimitBar.zip, unzip it, and move LimitBar.app to Applications. Signed with Developer ID and notarised by Apple. macOS 14+, Apple silicon."

info "Done. Review and publish the draft on GitHub when ready."
