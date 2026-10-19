#!/usr/bin/env bash
# Build one self-contained LimitBar.app with the Swift CLI helper and WidgetKit extension.
#
#   scripts/build-app.sh [--install] [--run] [--release]
#
# --install copies the bundle to ~/Applications. --run launches the resulting app.
# --release requires a Developer ID Application identity and signs with the
# hardened runtime and a secure timestamp, ready for notarisation.
# No Python runtime, repository path, LaunchAgent, or login item is installed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
APP_NAME="LimitBar"
APP_ID="com.dinilb.LimitBar"
EXT_NAME="LimitBarWidgetExtension"
EXT_ID="com.dinilb.LimitBar.LimitBarWidgetExtension"
VERSION="${LIMITBAR_VERSION:-1.0.0}"
MIN_MACOS="14.0"

INSTALL=0
RUN=0
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    --release) RELEASE=1 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

info() { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$1" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v swift >/dev/null || die "swift not found; install full Xcode"
command -v xcrun >/dev/null || die "xcrun not found; install full Xcode"
# An installed Xcode whose licence has not yet been accepted makes every xcrun
# fail. The app build itself can still use Command Line Tools; Swift Testing is
# the only step that requires the full licensed Xcode toolchain.
if ! SDK_PATH="$(xcrun --show-sdk-path --sdk macosx 2>/dev/null)"; then
  if [[ -d /Library/Developer/CommandLineTools ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
    warn "full Xcode is unavailable or unlicensed; building with Command Line Tools"
  else
    die "could not locate a usable macOS SDK"
  fi
fi
# Fail before touching build/ if a release build has nothing to sign with.
if [[ $RELEASE -eq 1 && -z "${CODESIGN_IDENTITY:-}" ]] \
  && ! security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application'; then
  die "--release needs a Developer ID Application certificate in the keychain (Xcode › Settings › Accounts › Manage Certificates)"
fi

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos${MIN_MACOS}"

# Build metadata that Xcode normally injects and a hand-assembled bundle does
# not. PlugInKit validates an extension against these before it will hand it to
# chronod, so a widget bundle missing CFBundleSupportedPlatforms or the DT* keys
# is discovered, registered, and then silently never loaded — no gallery entry
# and nothing in the log, because nothing ever tried.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
OS_BUILD="$(sw_vers -buildVersion)"
# DTXcode is zero-padded MMmp: 26.6 -> 2660, 16.2 -> 1620.
if XCODE_RAW="$(xcodebuild -version 2>/dev/null)"; then
  XCODE_VERSION="$(printf '%s' "$XCODE_RAW" | awk '/^Xcode/ {print $2; exit}')"
  XCODE_BUILD="$(printf '%s' "$XCODE_RAW" | awk '/Build version/ {print $3; exit}')"
  DT_XCODE="$(printf '%s' "$XCODE_VERSION" | awk -F. '{printf "%d%d0", $1, ($2 == "" ? 0 : $2)}')"
else
  XCODE_BUILD=""
  DT_XCODE=""
fi

# Shared Info.plist fragment. Both the app and the extension carry it; the
# extension is the one that strictly needs it, but a container app that
# disagrees with its own plug-in is not worth debugging later.
build_metadata_plist() {
  cat <<META
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>DTPlatformName</key><string>macosx</string>
  <key>DTPlatformVersion</key><string>$SDK_VERSION</string>
  <key>DTPlatformBuild</key><string>$SDK_BUILD</string>
  <key>DTSDKName</key><string>macosx$SDK_VERSION</string>
  <key>DTSDKBuild</key><string>$SDK_BUILD</string>
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>BuildMachineOSBuild</key><string>$OS_BUILD</string>${DT_XCODE:+
  <key>DTXcode</key><string>$DT_XCODE</string>}${XCODE_BUILD:+
  <key>DTXcodeBuild</key><string>$XCODE_BUILD</string>}
META
}

APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXT_BUNDLE="$APP_BUNDLE/Contents/PlugIns/$EXT_NAME.appex"
HELPERS_DIR="$APP_BUNDLE/Contents/Helpers"

info "Building the Swift app and CLI"
swift build --package-path "$REPO_ROOT" --disable-sandbox -c release --product LimitBarMenuBar
swift build --package-path "$REPO_ROOT" --disable-sandbox -c release --product limitbar
BIN_PATH="$(swift build --package-path "$REPO_ROOT" --disable-sandbox -c release --show-bin-path)"
[[ -x "$BIN_PATH/LimitBarMenuBar" ]] || die "LimitBarMenuBar did not build"
[[ -x "$BIN_PATH/limitbar" ]] || die "limitbar did not build"

info "Assembling $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$HELPERS_DIR" "$APP_BUNDLE/Contents/PlugIns"
cp "$BIN_PATH/LimitBarMenuBar" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BIN_PATH/limitbar" "$HELPERS_DIR/limitbar"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>LimitBar</string>
  <key>CFBundleIdentifier</key><string>$APP_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
$(build_metadata_plist)
</dict></plist>
PLIST

info "Compiling the sandboxed widget extension"
mkdir -p "$EXT_BUNDLE/Contents/MacOS"
DOMAIN_DIR="$BUILD_DIR/domain"
rm -rf "$DOMAIN_DIR"
mkdir -p "$DOMAIN_DIR"
swiftc \
  -emit-module -emit-library -static \
  -module-name LimitBarDomain \
  -swift-version 6 \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -O \
  -emit-module-path "$DOMAIN_DIR/LimitBarDomain.swiftmodule" \
  -o "$DOMAIN_DIR/libLimitBarDomain.a" \
  "$REPO_ROOT"/Sources/LimitBarDomain/*.swift

swiftc \
  -parse-as-library \
  -DWIDGET_EXTENSION \
  -swift-version 6 \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -O \
  -module-name "$EXT_NAME" \
  -I "$DOMAIN_DIR" -L "$DOMAIN_DIR" -lLimitBarDomain \
  -framework WidgetKit -framework SwiftUI -framework Foundation \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT_BUNDLE/Contents/MacOS/$EXT_NAME" \
  "$REPO_ROOT"/Sources/LimitBarWidget/*.swift

cat > "$EXT_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$EXT_NAME</string>
  <key>CFBundleDisplayName</key><string>LimitBar</string>
  <key>CFBundleIdentifier</key><string>$EXT_ID</string>
  <key>CFBundleExecutable</key><string>$EXT_NAME</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
$(build_metadata_plist)
</dict></plist>
PLIST

ENTITLEMENTS="$BUILD_DIR/widget.entitlements"
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST

# The menu bar app runs fine ad-hoc signed. The widget extension is the part
# that may not: chronod will register an ad-hoc extension and then decline to
# surface it in the widget gallery, with no error anywhere. Prefer a real
# identity when the machine has one; a free Apple ID yields an Apple Development
# certificate through Xcode's account settings.
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [[ $RELEASE -eq 1 ]]; then
  # Notarisation needs Developer ID, the hardened runtime and a secure timestamp
  # on every piece of nested code.
  if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk '/Developer ID Application/ { print $2; exit }')"
  fi
  [[ -n "$SIGN_ID" ]] || die "--release needs a Developer ID Application certificate in the keychain (Xcode › Settings › Accounts › Manage Certificates)"
  SIGN_FLAGS=(--options runtime --timestamp)
  info "Signing nested code inside-out with Developer ID ${SIGN_ID:0:10}…"
else
  if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk '/Apple Development|Developer ID Application/ { print $2; exit }')"
  fi
  SIGN_FLAGS=(--timestamp=none)
  if [[ -n "$SIGN_ID" ]]; then
    info "Signing nested code inside-out with identity ${SIGN_ID:0:10}…"
  else
    SIGN_ID="-"
    info "Ad-hoc signing nested code inside-out"
    warn "no code-signing identity found — signing ad-hoc. The menu bar app is unaffected, but macOS may refuse to list the widget in the gallery. Sign in to Xcode (Settings › Accounts) with any Apple ID for a free Apple Development certificate, then re-run. Override with CODESIGN_IDENTITY=<hash>."
  fi
fi

codesign --force --sign "$SIGN_ID" "${SIGN_FLAGS[@]}" "$HELPERS_DIR/limitbar"
codesign --force --sign "$SIGN_ID" "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$EXT_BUNDLE"
codesign --force --sign "$SIGN_ID" "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE" || die "bundle signature verification failed"

# A widget bundle missing these is registered by PlugInKit and then never
# loaded, which looks exactly like "the widget does not exist" — no gallery
# entry, no crash, nothing in the log. Cheap to assert, miserable to rediscover.
for key in CFBundleSupportedPlatforms DTPlatformName DTSDKName DTSDKBuild CFBundleInfoDictionaryVersion; do
  plutil -extract "$key" raw -o /dev/null "$EXT_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || die "widget Info.plist is missing $key; WidgetKit will ignore the extension"
done

TARGET_APP="$APP_BUNDLE"
if [[ $INSTALL -eq 1 ]]; then
  info "Installing to ~/Applications"
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP_BUNDLE" "$HOME/Applications/"
  TARGET_APP="$HOME/Applications/$APP_NAME.app"
  codesign --verify --deep --strict "$TARGET_APP" || die "installed signature verification failed"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$TARGET_APP" 2>/dev/null || warn "Launch Services registration failed"

info "Done"
printf '    app:    %s\n' "$TARGET_APP"
printf '    helper: %s/Contents/Helpers/limitbar\n' "$TARGET_APP"
printf '    widget: %s/Contents/PlugIns/%s.appex\n' "$TARGET_APP" "$EXT_NAME"
printf '\nNo LaunchAgent was installed. Use the app menu to opt in to ~/.local/bin/limitbar.\n'

if [[ $RUN -eq 1 ]]; then
  info "Launching"
  open "$TARGET_APP"
fi
