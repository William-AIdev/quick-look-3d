#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/QuickLook3D/Extension/Resources/renderer"
if [ "${QL_RENDERER_PREBUILT:-NO}" = YES ]; then
  test -s "$DEST/index.html" || { echo "error: prebuilt renderer missing" >&2; exit 1; }
  exit 0
fi
command -v node >/dev/null || { echo "error: Node required" >&2; exit 1; }
cd "$ROOT/renderer"
npm ci
npm run build
mkdir -p "$DEST"
cp dist/index.html "$DEST/index.html"
cp "$ROOT/THIRD_PARTY_LICENSES.md" "$DEST/THIRD_PARTY_LICENSES.md"
