# Folder preload, persistent settings, and memory validation

This branch adds an app workspace for preparing previews on disk and sharing settings with the Quick Look extension. It follows PR01–05; it does not implement thumbnails, a model library, or GPU-ready scene caching.

## User behavior

Drop one folder into the app or choose it with the folder picker. The scanner includes GLB, VRM, VRMA, and FBX (case insensitive), optionally recurses, and skips symbolic links, hidden files, and package contents. Only supported regular files count toward the confirmation: 100 starts directly; 101 or more asks before reading model contents or preparing cache entries. Scanning reads directory metadata. Processing is sequential, shows progress and the latest 100 results, and supports cancellation. An in-progress ImageIO operation completes before cancellation takes effect.

Settings save automatically and apply to the next preview. Economy is the default: embedded PNG/JPEG textures at most 1024 pixels, pixel ratio 1, animation capped at 30 FPS. Balanced uses 2048 / 1.5; Original retains textures and uses pixel ratio 2. Animation can be disabled or set to 15/30/60 FPS. Static models stop scheduled frames when idle, and hidden animations pause. The scheduler still receives display-rate RAF callbacks while animating but caps actual draws.

The disk cache defaults to 1 GiB and input files to 256 MiB. Both are configurable. The input limit is a file-size limit, not a hard bound on decoded images, scene memory, or RSS. The app releases each prepared payload before moving to the next file; it does not keep the whole folder resident. Close the app after preparation; the extension reads the persisted data independently.

## What is cached

For binary GLB/VRM containing supported embedded PNG/JPEG images, ImageIO makes smaller textures and rewrites buffer-view offsets. Meshopt offsets and Draco geometry data are preserved. Unknown buffer-view extensions, shared non-image views, animated images, external textures and other image encodings are left unchanged. Original files are never overwritten. FBX and animation-only VRMA are cached as original binary data; every preview still parses its scene. Geometry, bones, blend shapes, and animation tracks are not simplified.

Keys include the standardized source path, file size, fresh modification time, texture limit, and cache schema. Cache payloads have SHA-256 integrity checks. Changed file metadata or quality creates a new variant. A source rewritten while deliberately preserving size and modification time is outside this metadata-based invalidation model. Entries use recent access times for eviction, and budgets include payload and manifest bytes. Clear cache preserves settings. Orphaned pairs from interrupted writes are cleaned up on quota enforcement. NSFileCoordinator serializes shared store access; individual writes are atomic. Preview preparation is serial and superseded requests cancel at processing checkpoints.

Model bytes now cross into WKWebView through a request-scoped qlmodel URL scheme rather than a base64 JavaScript string. HTTP-style status and CORS headers are supplied for fetch. The legacy base64 message remains only for browser/test compatibility. The native scheme retains only the latest transfer and releases it after the first frame or error.

## Local sandbox sharing and signing

Both app and extension remain sandboxed. Current local builds share only:

    ~/Library/Application Support/QuickLook3D-Shared/PreviewWorkspace/

Both entitlements grant a home-relative read/write temporary exception limited to the dedicated QuickLook3D-Shared directory. The path resolves the real account home with getpwuid, rather than the sandbox container home. App Groups were tested as an initial option, but Xcode required provisioning profiles for both targets; this would break the existing ad-hoc build. The scoped directory keeps the local build usable without changing developer accounts, provisioning profiles, or the installed app. A distribution/App Store migration to properly provisioned App Groups remains separate work; App Store acceptance of temporary exceptions is not validated here.

The shared regression signs a probe first with the app entitlements and then with a separate extension identity. One process writes settings and a prepared payload, and the second process verifies the saved quality/FPS and a cache hit. This verifies real sandbox access across process identities. It does not replace testing the installed Finder host.

## Reproduce

Run scripts sequentially because native compilers share build/main.swift.

	bash scripts/build.sh
	node renderer/generate-fixtures.mjs
	bash scripts/test-native.sh
	bash scripts/test-shared.sh
	python3 scripts/process-recovery.py "$PWD"
	bash scripts/test-performance.sh

Optional QL_TEST_FBX, QL_TEST_VRM and QL_TEST_VRMA paths add real assets to the native regression. QL_TEST_VRM also enables the real-avatar memory comparison. Test assets stay read only. Logs, snapshots, complete RSS samples and per-load timings are in build/. Compact measured results are in preload-validation.json.

The VRMA check used pixiv/three-vrm's packages/three-vrm-animation/examples/models/test.vrma at commit 3caf7a21ee68f0d5dfa363ab3d577450bbf60136. Download URL: https://raw.githubusercontent.com/pixiv/three-vrm/3caf7a21ee68f0d5dfa363ab3d577450bbf60136/packages/three-vrm-animation/examples/models/test.vrma . SHA-256: 38d0fd12d61e896f1a970b5e358ebb41a96c8d5ee8e284496ea18f0ba1f04e7b. Downloaded under build/ for local validation, not redistributed with the app.

## Local memory measurements

Measured on macOS 27.2 arm64 with 640×480 previews. Each row is one fresh native host/WebView process loading the same model six times, with animation disabled. Samples are approximately 0.1 seconds apart. Cold means the prepared disk cache is cleared before the first load; warm retains it from the preceding run. Repeated timings are the median of loads 2–6. First loads include WebView initialization. These are observed examples, not a statistical benchmark or an upstream-before/after comparison.

| Asset and warm-cache quality | Native peak RSS MiB | WebContent peak RSS MiB | GPU process peak RSS MiB | Repeat median ms |
|---|---:|---:|---:|---:|
| 4096 texture, Original | 86.17 | 207.67 | 414.19 | 115.2 |
| 4096 texture, Economy | 83.09 | 69.64 | 84.22 | 32.9 |
| AvatarSample_A.vrm, Original | 100.80 | 262.44 | 494.98 | 375.7 |
| AvatarSample_A.vrm, Economy | 95.62 | 249.23 | 315.05 | 247.0 |

The real VRM GPU-process peak fell about 36%, with about 5% lower WebContent RSS in this sized-viewport run; earlier exploratory runs varied. Economy's cold preprocessing raised native-host peak RSS to 153.23 MiB versus 100.72 MiB for Original; preparing in the app moves that one-time work out of a later cache-hit preview. A sandboxed app launched at the idle workspace reached 113.69 MiB over approximately 2.25 seconds. Do not add per-role maxima as if they occurred simultaneously.

Native RSS belongs to the launched PID. WebKit processes have launchd as their parent; the measurement records candidates absent before launch and observed during the isolated run. They are correlated new processes, not responsibility/coalition-verified attribution. Concurrent unrelated WebKit launches can contaminate those numbers. RSS is neither physical footprint nor exclusive GPU/VRAM allocation on unified memory; a GPU process can retain deferred resources during repeated replacements. CPU usage, power, physical footprint and long-duration VRM leak behavior are not measured by this script.

Recommended starting settings: Economy / 30 FPS, or disable animation for the lowest recurring load. Preload frequently used folders and then close the app. Use Original only where texture detail matters. Disk persistence avoids repeated texture conversion, but does not eliminate file validation, scene parsing or GPU upload.

## Acceptance

| Requirement | Result | Evidence |
|---|---|---|
| 100/101 threshold, decline before processing | Pass | store-regression.log |
| Recursive filtering, symlink skip, progress and cancel | Pass | store-regression.log; production UI snapshot |
| Persistent settings and extension-identity cache reuse | Pass | shared-regression.log |
| Invalidation, integrity, quota, clear and input limit | Pass | store-regression.log |
| 1024 texture output + Draco/Meshopt compatibility offline | Pass | store-regression.log; wk-regression.log |
| 15 FPS cap, animation-off idle, visibility, 100 replacements | Pass | wk-regression.log |
| Native request callbacks and actual WebContent SIGKILL recovery | Pass | native-regression.log; process-regression.log |
| Real FBX, VRM, official VRMA | Pass | optional local suites; validation JSON |
| Workbench layout and memory | Pass | workspace.png; memory-workspace.json |
| Finder drag gesture and installed extension integration | Unverified | installed /Applications app was not replaced or registered |
| Notarization/App Store distribution and old warning attribution | Unverified | outside the local build validation |
