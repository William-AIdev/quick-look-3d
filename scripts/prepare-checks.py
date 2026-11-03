import json,pathlib
r=pathlib.Path(__file__).resolve().parent.parent
p=r/'renderer/package.json'; d=json.loads(p.read_text()); lock=json.loads((r/'renderer/package-lock.json').read_text())
for group in ('dependencies','devDependencies'):
 for k in d[group]: d[group][k]=lock['packages']['node_modules/'+k]['version']
d['scripts']['typecheck']='tsc --noEmit'; d['scripts']['build']='npm run typecheck && vite build';p.write_text(json.dumps(d,indent=2)+'\n')
p=r/'scripts/build.sh';s=p.read_text();a=s.index('echo "==> 1/5');b=s.index('echo "==> 3/5');s=s[:a]+'bash "$ROOT/scripts/build-renderer.sh"\n\n'+s[b:];s=s.replace('  build\n','  QL_RENDERER_PREBUILT=YES \\\n  build\n');p.write_text(s)
p=r/'project.yml';s=p.read_text();a=s.index('          set -e\n');b=s.index('        basedOnDependencyAnalysis',a);s=s[:a]+'          bash "$SRCROOT/scripts/build-renderer.sh"\n'+s[b:];p.write_text(s)
(r/'.node-version').write_text('24.18.0\n')
