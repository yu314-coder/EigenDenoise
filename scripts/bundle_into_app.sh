#!/usr/bin/env bash
# Copy the prebuilt python venv (built by build_bundle_venv.sh) into a
# .app bundle's Contents/Resources/python/, replace any absolute /usr/local
# / Homebrew interpreter symlinks with a relocatable copy, then code-sign
# every dylib / .so / executable inside it with the team identity.
#
# This is invoked automatically by the Xcode "Run Script" build phase
# (see project.pbxproj), but is also runnable manually:
#
#     scripts/bundle_into_app.sh "$BUILT_PRODUCTS_DIR/EigenDenoise.app"
#
set -euo pipefail

if [[ "${1:-}" == "" ]]; then
    APP="${BUILT_PRODUCTS_DIR:-}/${PRODUCT_NAME:-EigenDenoise}.app"
else
    APP="$1"
fi
if [[ ! -d "$APP" ]]; then
    echo "[bundle] error: .app not found at $APP"
    exit 1
fi

HERE="$(cd "$(dirname "$0")"/.. && pwd)"
SRC="$HERE/python_bundle/.venv"
DEST="$APP/Contents/Resources/python/.venv"

if [[ ! -d "$SRC" ]]; then
    echo "[bundle] error: bundling venv not built — run scripts/build_bundle_venv.sh first"
    exit 1
fi

echo "[bundle] copying venv → $DEST"
rm -rf "$APP/Contents/Resources/python"
mkdir -p "$APP/Contents/Resources/python"
cp -R "$SRC" "$DEST"

# Replace the symlinked python interpreter with a real copy of the system one
# so it works once the .app is moved off this Mac. The venv's bin/python is
# usually a symlink into /Library/Frameworks/Python.framework/...
PYBIN="$DEST/bin/python3"
if [[ -L "$PYBIN" ]]; then
    REAL=$(readlink -f "$PYBIN" 2>/dev/null || python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$PYBIN")
    if [[ -f "$REAL" ]]; then
        echo "[bundle] resolving interpreter symlink: $PYBIN → $REAL"
        rm "$PYBIN"
        cp "$REAL" "$PYBIN"
        chmod +x "$PYBIN"
        # Refresh other names that point at it.
        for nm in python python3.14 python3.13 python3.12 python3.11; do
            ln -sf "python3" "$DEST/bin/$nm" 2>/dev/null || true
        done
    fi
fi

# Copy the bridge helper script next to the venv so the Swift launcher can
# find it via the bundle.
cp "$HERE/EigenDenoise/Resources/python/run_rmt_denoise.py" \
   "$APP/Contents/Resources/python/run_rmt_denoise.py"

# Strip stray __pycache__ to slim the bundle.
find "$DEST" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

# Code-sign every binary inside the venv. Apple requires every Mach-O inside
# the .app share the team identity for App Store / notarisation. We sign with
# `--options runtime` to opt into the hardened runtime; the entitlements on
# the embedded interpreter itself are inherited from the parent app at launch
# via `com.apple.security.inherit`.
SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${CODE_SIGN_IDENTITY:--}}"
if [[ -z "$SIGN_ID" || "$SIGN_ID" == "-" ]]; then
    SIGN_ID="-"   # ad-hoc; OK for local Debug runs, App Store needs a real cert
fi
echo "[bundle] code-signing dylibs / executables with identity: $SIGN_ID"

INHERIT_ENT="$HERE/scripts/python_inherit.entitlements"
cat > "$INHERIT_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>      <true/>
  <key>com.apple.security.inherit</key>           <true/>
  <key>com.apple.security.cs.allow-jit</key>      <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key> <true/>
  <key>com.apple.security.cs.disable-library-validation</key>       <true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key> <true/>
</dict>
</plist>
PLIST

# 1. Sign every .dylib / .so first (deepest leaves first).
find "$DEST" \( -name '*.dylib' -o -name '*.so' \) -type f -print0 | \
    xargs -0 -I {} codesign --force --options runtime --sign "$SIGN_ID" {} \
    2>&1 | grep -v "replacing existing signature" || true

# 2. Sign python interpreter with inherit entitlements.
codesign --force --options runtime \
    --entitlements "$INHERIT_ENT" \
    --sign "$SIGN_ID" "$PYBIN"

# 3. Re-sign the .app bundle as a whole so the embedded changes are accepted.
APP_ENT="$HERE/EigenDenoise/EigenDenoise.entitlements"
codesign --force --options runtime \
    --entitlements "$APP_ENT" \
    --deep --sign "$SIGN_ID" "$APP"

echo "[bundle] done — $DEST  ($(du -sh "$DEST" | awk '{print $1}'))"
