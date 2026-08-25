#!/usr/bin/env bash
#
# Builds UnDupe.app from the Swift package, then optionally signs, notarizes and
# packages it for distribution.
#
#   Scripts/build-app.sh                     # release, ad-hoc signed (local dev)
#   Scripts/build-app.sh debug               # debug, ad-hoc signed
#   Scripts/build-app.sh --sign              # Developer ID + hardened runtime
#   Scripts/build-app.sh --dist              # release + sign + notarize + dmg
#
# Options
#   --sign            Sign with a Developer ID Application identity, hardened
#                     runtime and a secure timestamp (instead of ad-hoc).
#   --notarize        Implies --sign. Submit to Apple's notary service, wait for
#                     the verdict, and staple the ticket to the bundle.
#   --dmg             Wrap the app in a drag-to-Applications disk image.
#   --universal       Build a universal (arm64 + x86_64) binary. Implied by
#                     --dist; a native-only build will not launch at all on an
#                     Intel Mac, so anything shipped must have this.
#   --dist            Shorthand for: release --sign --notarize --dmg
#   --identity NAME   Signing identity (default: the first "Developer ID
#                     Application" in the keychain, or $UNDUPE_SIGN_IDENTITY).
#   --profile NAME    notarytool keychain profile (default: $UNDUPE_NOTARY_PROFILE
#                     or "unDupe"). Case-sensitive.
#
# Ad-hoc builds need a right-click ▸ Open on first launch. Signed+notarized
# builds open with a normal double-click. Either way, Full Disk Access is
# granted by the user in System Settings ▸ Privacy & Security ▸ Full Disk Access.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/UnDupe.app"
CONTENTS="$APP/Contents"

CONFIG="release"
DO_SIGN=false
DO_NOTARIZE=false
DO_DMG=false
DO_UNIVERSAL=false
IDENTITY="${UNDUPE_SIGN_IDENTITY:-}"
# Keychain profile names are case-sensitive; this is the one that was created.
PROFILE="${UNDUPE_NOTARY_PROFILE:-unDupe}"

die() { echo "✗ $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release) CONFIG="$1" ;;
        --sign)        DO_SIGN=true ;;
        --notarize)    DO_SIGN=true; DO_NOTARIZE=true ;;
        --dmg)         DO_DMG=true ;;
        --universal)   DO_UNIVERSAL=true ;;
        --dist)        CONFIG="release"; DO_SIGN=true; DO_NOTARIZE=true
                       DO_DMG=true; DO_UNIVERSAL=true ;;
        --identity)    IDENTITY="${2:-}"; shift ;;
        --profile)     PROFILE="${2:-}"; shift ;;
        -h|--help)     sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/build/UnDupe-$VERSION.dmg"

# ---------------------------------------------------------------- build

# Both swift build invocations must get identical flags: --show-bin-path
# reports a different directory for a universal build (.build/apple/Products).
ARCH_FLAGS=()
if $DO_UNIVERSAL; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    echo "▸ Compiling UnDupe ($CONFIG, universal arm64 + x86_64)…"
else
    echo "▸ Compiling UnDupe ($CONFIG, native only)…"
fi
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product UnDupe

BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product UnDupe --show-bin-path)"
EXECUTABLE="$BIN_DIR/UnDupe"
[[ -f "$EXECUTABLE" ]] || die "Built executable not found at $EXECUTABLE"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$EXECUTABLE" "$CONTENTS/MacOS/UnDupe"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# App icon. Regenerate if missing so a fresh checkout still gets one.
if [[ ! -f "$ROOT/Resources/UnDupe.icns" ]]; then
    echo "▸ Generating app icon…"
    swift "$ROOT/Scripts/make-icon.swift"
fi
cp "$ROOT/Resources/UnDupe.icns" "$CONTENTS/Resources/UnDupe.icns"

# ---------------------------------------------------------------- sign

resolve_identity() {
    [[ -n "$IDENTITY" ]] && return
    IDENTITY="$(security find-identity -v -p codesigning \
        | grep 'Developer ID Application' | head -1 \
        | sed -E 's/.*"(.*)".*/\1/')"
    [[ -n "$IDENTITY" ]] || die "No 'Developer ID Application' identity in the keychain.
  Install one from developer.apple.com ▸ Certificates, or pass --identity NAME."
}

if $DO_SIGN; then
    resolve_identity
    echo "▸ Code-signing as: $IDENTITY"
    # No --deep: the bundle holds a single statically-linked executable and no
    # nested code, and --deep is deprecated for exactly this reason.
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/Resources/UnDupe.entitlements" \
        --sign "$IDENTITY" \
        "$APP"
else
    echo "▸ Code-signing (ad-hoc)…"
    codesign --force --deep --sign - \
        --entitlements "$ROOT/Resources/UnDupe-debug.entitlements" \
        "$APP"
fi

codesign --verify --strict --verbose=1 "$APP"

# ---------------------------------------------------------------- notarize

# Submits `$1` (an .app or .dmg) to Apple, waits for the verdict, and staples.
notarize() {
    local target="$1"
    local upload="$target"

    # notarytool only accepts .zip/.dmg/.pkg — a bundle has to be zipped first.
    if [[ "$target" == *.app ]]; then
        upload="$ROOT/build/UnDupe-notarize.zip"
        rm -f "$upload"
        ditto -c -k --keepParent "$target" "$upload"
    fi

    echo "▸ Submitting $(basename "$target") to the notary service (this takes a few minutes)…"
    xcrun notarytool submit "$upload" --keychain-profile "$PROFILE" --wait

    echo "▸ Stapling ticket…"
    xcrun stapler staple "$target"
    if [[ "$upload" == *notarize.zip ]]; then rm -f "$upload"; fi
}

if $DO_NOTARIZE; then
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        die "No notarytool credentials stored under the profile \"$PROFILE\".
  Create them once (interactive — it needs your Apple ID and an app-specific
  password from appleid.apple.com, plus your Team ID):

    xcrun notarytool store-credentials \"$PROFILE\" \\
        --apple-id <your-apple-id-email> \\
        --team-id <your-team-id> \\
        --password <app-specific-password>

  Then re-run this script."
    fi
    # Staple the app itself even when a DMG follows. A ticket stapled only to
    # the disk image is gone once the user drags the app to /Applications, and
    # that copy then needs an online notary check on first launch. Two
    # round-trips (a couple of minutes each) buys an app that opens offline.
    notarize "$APP"
fi

# ---------------------------------------------------------------- package

if $DO_DMG; then
    echo "▸ Building disk image…"
    STAGING="$(mktemp -d)"
    trap 'rm -rf "$STAGING"' EXIT
    cp -R "$APP" "$STAGING/UnDupe.app"
    ln -s /Applications "$STAGING/Applications"

    rm -f "$DMG"
    hdiutil create -volname "UnDupe $VERSION" -srcfolder "$STAGING" \
        -ov -format ULFO -quiet "$DMG"

    if $DO_SIGN; then
        codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    fi
    if $DO_NOTARIZE; then notarize "$DMG"; fi
fi

# ---------------------------------------------------------------- report

echo
echo "✓ Built $APP ($(lipo -archs "$CONTENTS/MacOS/UnDupe"))"
if $DO_SIGN; then
    # "rejected" here is expected for a signed-but-not-notarized build — that
    # is exactly what notarization fixes.
    echo "▸ Gatekeeper assessment:"
    spctl --assess --type exec --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true
fi
if $DO_DMG; then echo "✓ Built $DMG"; fi
echo "  Launch with:  open \"$APP\""
