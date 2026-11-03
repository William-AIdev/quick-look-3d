#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/ViewerRegression.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources/renderer"
cp renderer/dist/index.html "$APP/Resources/renderer/index.html"
mkdir -p build/viewer-source
cp scripts/viewer-regression.swift build/viewer-source/main.swift
xcrun swiftc QuickLook3D/Shared/*.swift QuickLook3D/Extension/*.swift QuickLook3D/Rendering/*.swift QuickLook3D/App/LibraryModel.swift QuickLook3D/App/BrowserThumbnailService.swift QuickLook3D/App/WorkspaceView.swift QuickLook3D/App/ViewerSettingsView.swift build/viewer-source/main.swift -o "$APP/MacOS/ViewerRegression"
"$APP/MacOS/ViewerRegression" "$ROOT"
