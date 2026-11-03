#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="build/MemoryProbe.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources/renderer"
cp renderer/dist/index.html "$APP/Resources/renderer/index.html"
cp scripts/memory-probe.swift build/main.swift
xcrun swiftc QuickLook3D/Shared/*.swift QuickLook3D/Extension/*.swift build/main.swift -o "$APP/MacOS/MemoryProbe"
python3 scripts/measure-memory.py "$ROOT" renderer/tests/fixtures/textured.glb
if [[ -n "${QL_TEST_VRM:-}" ]]; then
    python3 scripts/measure-memory.py "$ROOT" "$QL_TEST_VRM" --output build/memory-real-vrm.json
fi
cp scripts/ui-probe.swift build/main.swift
xcrun swiftc QuickLook3D/Shared/*.swift QuickLook3D/Extension/*.swift QuickLook3D/Rendering/*.swift QuickLook3D/App/LibraryModel.swift QuickLook3D/App/BrowserThumbnailService.swift QuickLook3D/App/ViewerSettingsView.swift QuickLook3D/App/WorkspaceView.swift build/main.swift -o build/ui-probe
build/ui-probe "$ROOT"
python3 - <<'PY'
import json, pathlib, subprocess, time
binary=pathlib.Path('build/Build/Products/Release/QuickLook3D.app/Contents/MacOS/QuickLook3D').resolve()
child=subprocess.Popen([str(binary)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
values=[]
try:
    for _ in range(15):
        time.sleep(.15)
        text=subprocess.check_output(['/bin/ps','-o','rss=','-p',str(child.pid)],text=True).strip()
        if text: values.append(int(text)/1024)
finally:
    child.terminate(); child.wait(timeout=10)
report={'pid':child.pid,'peakRSSMiB':round(max(values),2),'lastRSSMiB':round(values[-1],2),'scenario':'Built sandbox app, idle workspace, no import, ~2.25 seconds'}
pathlib.Path('build/memory-workspace.json').write_text(json.dumps(report,indent=2))
print('Workspace',report)
PY
