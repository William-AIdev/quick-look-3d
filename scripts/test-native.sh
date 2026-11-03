#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
xcrun swiftc scripts/wk-regression.swift -o build/wk-regression
build/wk-regression "$ROOT" > build/wk-regression.log 2>&1
APP="$ROOT/build/NativeRegression.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources/renderer"
cp renderer/dist/index.html "$APP/Resources/renderer/index.html"
cp scripts/native-regression.swift build/main.swift
xcrun swiftc QuickLook3D/Extension/PreviewViewController.swift build/main.swift -o "$APP/MacOS/NativeRegression"
"$APP/MacOS/NativeRegression" "$ROOT" > build/native-regression.log 2>&1
