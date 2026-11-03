#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROBE="build/SharedProbe.app"
mkdir -p "$PROBE/Contents/MacOS" "$PROBE/Contents/Resources"
cp renderer/tests/fixtures/plain.glb "$PROBE/Contents/Resources/plain.glb"
cp scripts/shared-probe.swift build/main.swift
xcrun swiftc QuickLook3D/Shared/*.swift build/main.swift -o "$PROBE/Contents/MacOS/SharedProbe"
python3 - <<'PY'
import plistlib
from pathlib import Path
Path('build/SharedProbe.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.sawazen.QuickLook3D.SharedProbe','CFBundleExecutable':'SharedProbe','CFBundlePackageType':'APPL'}))
PY
TOKEN="$(uuidgen)"
codesign --force --sign - --entitlements QuickLook3D/App/QuickLook3D.entitlements "$PROBE"
"$PROBE/Contents/MacOS/SharedProbe" write "$TOKEN"
codesign --force --sign - --identifier com.sawazen.QuickLook3D.ExtensionProbe --entitlements QuickLook3D/Extension/QuickLook3DExtension.entitlements "$PROBE"
"$PROBE/Contents/MacOS/SharedProbe" read "$TOKEN"
