#!/usr/bin/env python3
import json, os, pathlib, signal, subprocess, sys
root=pathlib.Path(sys.argv[1]).resolve()
def pids():
    return {int(line.split(None,1)[0]) for line in subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True).splitlines() if 'com.apple.WebKit.WebContent' in line}
before=pids()
env=dict(os.environ, QL_TEST_PROCESS_KILL='1')
child=subprocess.Popen([str(root/'build/NativeRegression.app/Contents/MacOS/NativeRegression'),str(root)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
killed=None
with (root/'build/process-regression.log').open('w') as log:
    for line in child.stdout:
        log.write(line); log.flush()
        if line.strip()=='READY_FOR_KILL':
            targets=pids()-before
            if len(targets)!=1:
                child.terminate(); raise RuntimeError(f'Expected one newly created WebContent process, found {len(targets)}; did not kill any process')
            killed=targets.pop(); os.kill(killed,signal.SIGKILL)
    code=child.wait(timeout=30)
if code or killed is None: raise RuntimeError('Real process recovery regression failed; see build/process-regression.log')
print('PASS: actual WebContent process termination and native reload')
