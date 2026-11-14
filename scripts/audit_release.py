#!/usr/bin/env python3
"""Fail packaging/publication if local user data or machine paths are staged."""
from pathlib import Path
import subprocess,re,os
root=Path(__file__).resolve().parents[1]
files=subprocess.check_output(['git','-C',str(root),'ls-files','--cached','--others','--exclude-standard'],text=True).splitlines()
errors=[]
home=str(Path.home()).encode()
for name in files:
 p=root/name
 if any(x in p.parts for x in ['Build','Dist','Spec','Tools','xcuserdata']):errors.append(name+': private/build directory')
 if p.suffix.lower() in ['.mov','.mp4','.log','.p12','.pem','.key','.plist']:errors.append(name+': user/generated file')
 if p.is_file():
  data=p.read_bytes()
  if home!=b'/' and home in data:errors.append(name+': contains local home path')
  if re.search(rb'(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9]{32,})',data):errors.append(name+': potential credential')
if errors:raise SystemExit('\n'.join(errors))
print(f'Privacy audit passed: {len(files)} source files; no home paths, recordings, settings or keys.')
