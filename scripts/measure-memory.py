#!/usr/bin/env python3
"""Sample RSS of the native host and WebKit processes born during an isolated run."""
import argparse, json, pathlib, subprocess, time
p=argparse.ArgumentParser(); p.add_argument('root'); p.add_argument('source'); p.add_argument('--output', default='build/memory-results.json'); args=p.parse_args()
root=pathlib.Path(args.root).resolve()
def processes():
    output=subprocess.check_output(['/bin/ps','-axo','pid=,rss=,comm='],text=True)
    result={}
    for line in output.splitlines():
        fields=line.strip().split(None,2)
        if len(fields)==3:
            pid,rss,command=fields
            if 'com.apple.WebKit.' in command:
                role=next((name for name in ['WebContent','GPU','Networking'] if 'com.apple.WebKit.'+name in command),'Other')
                result[int(pid)]={'role':role,'rssKiB':int(rss)}
    return result
results=[]
for quality in ['original','economy']:
    for mode in ['cold','warm']:
        baseline=set(processes())
        log=root/f'build/memory-{quality}-{mode}-{pathlib.Path(args.source).stem}.log'
        samples=[]
        with log.open('w') as stream:
            child=subprocess.Popen([str(root/'build/MemoryProbe.app/Contents/MacOS/MemoryProbe'),str(root),quality,str(pathlib.Path(args.source).resolve()),mode],stdout=stream,stderr=subprocess.STDOUT)
            start=time.monotonic()
            while child.poll() is None:
                current=processes()
                born={pid:value for pid,value in current.items() if pid not in baseline}
                rss=subprocess.run(['/bin/ps','-o','rss=','-p',str(child.pid)],capture_output=True,text=True).stdout.strip()
                roles={'native':int(rss) if rss else 0,'WebContent':0,'GPU':0,'Networking':0}
                for value in born.values():
                    if value['role'] in roles: roles[value['role']]+=value['rssKiB']
                samples.append({'seconds':round(time.monotonic()-start,3),'rssKiB':roles,'webKitPids':sorted(born)})
                if time.monotonic()-start>100: child.terminate(); raise RuntimeError('memory probe exceeded 100 seconds')
                time.sleep(.1)
        text=log.read_text()
        if child.returncode or 'RESULT ' not in text: raise RuntimeError(text[-2500:])
        result=json.loads(next(line[7:] for line in text.splitlines() if line.startswith('RESULT ')))
        result['peakRSSMiB']={role:round(max(s['rssKiB'][role] for s in samples)/1024,2) for role in roles}
        result['samples']=samples
        result['attribution']='Native PID exact; WebKit candidates are PIDs absent before launch and observed during this run; RSS is not physical footprint or exclusive GPU memory.'
        results.append(result)
        print(quality,mode,result['peakRSSMiB'],flush=True)
(root/args.output).write_text(json.dumps(results,indent=2))
