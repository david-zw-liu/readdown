#!/bin/bash
set -euo pipefail

# Validates a Readdown release build to catch common issues
# before shipping. Run against the exported .app bundle.

APP_PATH="${1:-}"
EXPECTED_BUNDLE_ID="com.heya.readdown"

if [ -z "$APP_PATH" ]; then
    echo "Usage: $0 <path-to-Readdown.app>"
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "FAIL: App not found at $APP_PATH"
    exit 1
fi

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "==> Validating $APP_PATH"
echo ""

# ── SDK Version ──
echo "--- SDK Version (vtool) ---"

check_sdk() {
    local binary="$1"
    local label="$2"
    local sdk_ver
    sdk_ver=$(vtool -show "$binary" 2>/dev/null | grep "sdk " | head -1 | awk '{print $2}')
    local major="${sdk_ver%%.*}"
    if [ -n "$major" ] && [ "$major" -le 15 ] 2>/dev/null; then
        echo "  PASS: $label SDK version is $sdk_ver"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label SDK version is $sdk_ver (expected <= 15.x)"
        FAIL=$((FAIL + 1))
    fi
}

# Main app intentionally keeps SDK 26.x to get macOS Tahoe chrome on macOS 26+.
# Only the Sparkle binaries must stay <= SDK 15 for macOS 15 compatibility
# (installer XPC services that macOS 15 refuses to load).
check_sdk "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" "Sparkle Installer"
check_sdk "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" "Sparkle Autoupdate"

# ── Code Signing ──
echo ""
echo "--- Code Signing ---"

check "Main app signature valid" codesign --verify --deep --strict "$APP_PATH"

SIGNING_ID=$(codesign -dvv "$APP_PATH" 2>&1 | grep "Authority=Developer ID Application" | head -1 || echo "")
if [ -n "$SIGNING_ID" ]; then
    echo "  PASS: Signed with Developer ID"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Not signed with Developer ID Application"
    FAIL=$((FAIL + 1))
fi

# ── App Info.plist ──
echo ""
echo "--- App Info.plist ---"

APP_PLIST="$APP_PATH/Contents/Info.plist"
check "App Info.plist exists" test -f "$APP_PLIST"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PLIST" 2>/dev/null || echo "")
if [ "$BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ]; then
    echo "  PASS: Bundle ID is $EXPECTED_BUNDLE_ID"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Bundle ID is '$BUNDLE_ID' (expected $EXPECTED_BUNDLE_ID)"
    FAIL=$((FAIL + 1))
fi

# ── Sparkle Auto-Update ──
echo ""
echo "--- Sparkle Auto-Update ---"

check "Sparkle framework exists" test -d "$APP_PATH/Contents/Frameworks/Sparkle.framework"
check "Installer.xpc exists" test -d "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
check "SUFeedURL in Info.plist" /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_PLIST"
check "SUPublicEDKey in Info.plist" /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_PLIST"
check "SUEnableInstallerLauncherService in Info.plist" /usr/libexec/PlistBuddy -c "Print :SUEnableInstallerLauncherService" "$APP_PLIST"

# Verify entitlements include Sparkle mach-lookup exceptions (required for sandboxed apps)
APP_ENTITLEMENTS=$(codesign -d --entitlements - "$APP_PATH" 2>&1)
if echo "$APP_ENTITLEMENTS" | grep -q "readdown-spks" && echo "$APP_ENTITLEMENTS" | grep -q "readdown-spki"; then
    echo "  PASS: Entitlements include Sparkle mach-lookup exceptions"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Entitlements missing Sparkle mach-lookup exceptions (spks/spki)"
    FAIL=$((FAIL + 1))
fi

# ── Universal Binary ──
echo ""
echo "--- Architecture ---"

ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/ReadDown" 2>/dev/null || echo "")
if echo "$ARCHS" | grep -q "arm64" && echo "$ARCHS" | grep -q "x86_64"; then
    echo "  PASS: Universal binary (arm64 + x86_64)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Not universal binary (got: $ARCHS)"
    FAIL=$((FAIL + 1))
fi

# ── Summary ──
echo ""
echo "==> Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    echo "==> RELEASE VALIDATION FAILED"
    exit 1
else
    echo "==> All checks passed"
fi
