#!/usr/bin/env bash
# Build the minimal Python venv that ships inside the .app bundle.
# Run once after cloning / when requirements change. Output: ./python_bundle/.venv
set -euo pipefail

HERE="$(cd "$(dirname "$0")"/.. && pwd)"
DEST="$HERE/python_bundle/.venv"

if [[ -d "$DEST" ]]; then
    echo "[bundle-venv] $DEST exists — rebuilding from scratch"
    rm -rf "$DEST"
fi
mkdir -p "$HERE/python_bundle"

# Use the system python3 for the venv base — Apple-shipped Python 3.x is fine.
PY="${PYTHON_FOR_BUNDLE:-/usr/bin/env python3}"
echo "[bundle-venv] creating venv at $DEST with $PY"
$PY -m venv "$DEST"

"$DEST/bin/python" -m pip install --quiet --upgrade pip
"$DEST/bin/python" -m pip install --quiet \
    numpy \
    scipy \
    Pillow \
    rmt-denoise \
    torch

# Strip __pycache__ to slim things down.
find "$DEST" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

echo "[bundle-venv] versions:"
"$DEST/bin/python" -c "
import sys, numpy, scipy, PIL, rmt_denoise
print(f'  python      = {sys.version.split()[0]}')
print(f'  numpy       = {numpy.__version__}')
print(f'  scipy       = {scipy.__version__}')
print(f'  Pillow      = {PIL.__version__}')
print(f'  rmt_denoise = {rmt_denoise.__version__}')
"
echo "[bundle-venv] size: $(du -sh "$DEST" | awk '{print $1}')"
