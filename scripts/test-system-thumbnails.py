#!/usr/bin/env python3
"""Exercise the installed thumbnail extension through the public system API, then unregister it."""
import os, pathlib, plistlib, shutil, subprocess, uuid
root = pathlib.Path(__file__).resolve().parents[1]
applications = pathlib.Path.home() / 'Applications'
applications.mkdir(exist_ok=True)
app = applications / ('QuickLook3DThumbnailRegression-' + uuid.uuid4().hex + '.app')
source = root / 'build/Build/Products/Release/QuickLook3D.app'
ls = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
def run(*args):
    subprocess.run(args, cwd=root, check=True)
assert source.is_dir() and not app.exists()
shutil.copytree(source, app)
extensions = sorted((app / 'Contents/PlugIns').glob('*.appex'))
identity = 'com.sawazen.QuickLook3D.ThumbnailRegression' + uuid.uuid4().hex
try:
    for bundle in [app] + extensions:
        info = bundle / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleIdentifier'] = identity + ('.' + bundle.stem if bundle != app else '')
        data['CFBundleVersion'] = '99'
        info.write_bytes(plistlib.dumps(data))
    for extension in extensions:
        run('codesign', '--force', '--sign', '-', '--entitlements', str(root / 'QuickLook3D/Extension/QuickLook3DExtension.entitlements'), str(extension))
    run('codesign', '--force', '--sign', '-', '--entitlements', str(root / 'QuickLook3D/App/QuickLook3D.entitlements'), str(app))
    run(ls, '-f', str(app))
    for extension in extensions:
        run('pluginkit', '-a', str(extension))
        bundle_id = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
        run('pluginkit', '-e', 'use', '-i', bundle_id)
    run('xcrun', 'swiftc', 'scripts/system-thumbnail-probe.swift', '-o', 'build/system-thumbnail-probe')
    output = root / 'build/system-thumbnails'
    output.mkdir(exist_ok=True)
    fixture = output / ('independent-' + uuid.uuid4().hex + '.vrm')
    shutil.copyfile(root / 'renderer/tests/fixtures/plain.glb', fixture)
    run(str(root / 'build/system-thumbnail-probe'), str(fixture), str(output / 'vrm.png'))
    fixture = output / ('independent-' + uuid.uuid4().hex + '.glb')
    shutil.copyfile(root / 'renderer/tests/fixtures/plain.glb', fixture)
    run(str(root / 'build/system-thumbnail-probe'), str(fixture), str(output / 'glb.png'))
    if os.environ.get('QL_TEST_FBX'):
        fixture = output / ('independent-' + uuid.uuid4().hex + '.fbx')
        shutil.copyfile(os.environ['QL_TEST_FBX'], fixture)
        run(str(root / 'build/system-thumbnail-probe'), str(fixture), str(output / 'fbx.png'))
finally:
    for extension in extensions:
        subprocess.run(['pluginkit', '-r', str(extension)], check=False)
    subprocess.run([ls, '-u', str(app)], check=False)
    assert app.parent == applications and app.name.startswith('QuickLook3DThumbnailRegression-')
    shutil.rmtree(app)
