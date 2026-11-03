#!/usr/bin/env python3
"""Measure one isolated viewer regression; WebKit RSS attribution is candidate-based."""
import json, pathlib, subprocess, time
root = pathlib.Path(__file__).resolve().parents[1]
def processes():
    result = {}
    for line in subprocess.check_output(['/bin/ps', '-axo', 'pid=,rss=,comm='], text=True).splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3:
            continue
        pid, rss, command = fields
        if 'com.apple.WebKit.' in command or command.endswith('/ViewerRegression'):
            role = next((role for role in ['WebContent', 'GPU', 'Networking'] if 'com.apple.WebKit.' + role in command), 'native')
            result[int(pid)] = {'rssKiB': int(rss), 'role': role}
    return result
baseline = set(processes())
samples = []
with (root / 'build/viewer-regression.log').open('w') as output:
    child = subprocess.Popen(['bash', 'scripts/test-viewer.sh'], cwd=root, stdout=output, stderr=subprocess.STDOUT)
    start = time.monotonic()
    while child.poll() is None:
        born = {pid: value for pid, value in processes().items() if pid not in baseline}
        roles = {role: sum(value['rssKiB'] for value in born.values() if value['role'] == role) for role in ['native', 'WebContent', 'GPU', 'Networking']}
        samples.append({'seconds': round(time.monotonic() - start, 2), 'rssKiB': roles, 'pids': list(born), 'processes': born})
        if time.monotonic() - start > 480:
            child.terminate()
            raise RuntimeError('Viewer regression exceeded 480 seconds')
        time.sleep(.2)
if child.returncode:
    raise RuntimeError((root / 'build/viewer-regression.log').read_text()[-3000:])
result = {'method': 'RSS, new WebKit process candidates only; not physical footprint or exclusive GPU attribution',
          'elapsedSeconds': round(time.monotonic() - start, 2),
          'peakRSSMiB': {role: round(max(sample['rssKiB'][role] for sample in samples) / 1024, 2) for role in roles}, 'samples': samples}
(root / 'build/viewer-memory.json').write_text(json.dumps(result, indent=2))
print(json.dumps({key: value for key, value in result.items() if key != 'samples'}, indent=2))
