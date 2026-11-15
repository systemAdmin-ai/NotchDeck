#!/usr/bin/env python3
"""Render release screenshots with deterministic demo data in a separate process."""
from pathlib import Path
import subprocess,shlex
root=Path(__file__).resolve().parents[1]
work=root/'Build'/'asset-render'
work.mkdir(parents=True,exist_ok=True)
(work/'main.swift').write_text((root/'scripts/render_assets.swift').read_text())
text=(root/'build.sh').read_text()
command=text[text.index('swiftc -target'):text.index('# System-wide media')].strip().split('2>&1')[0].replace('\\\n',' ')
args=shlex.split(command)
args[args.index('-o')+1]=str(work/'NotchDeckAssetRenderer')
args[args.index('Sources/main.swift')]=str(work/'main.swift')
args+=['-module-cache-path',str(root/'Build'/'ModuleCache')]
subprocess.run(args,cwd=root,check=True)
subprocess.run([str(work/'NotchDeckAssetRenderer'),str(work/'frames')],cwd=root,check=True)
