#!/usr/bin/env python3
"""Verify Finder icon metadata and the icon embedded in the distributable bundle."""
import plistlib,struct,sys
from pathlib import Path
app=Path(sys.argv[1])
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
name=info['CFBundleIconFile']
icon=app/'Contents/Resources'/(name if name.endswith('.icns') else name+'.icns')
data=icon.read_bytes()
assert data[:4]==b'icns' and struct.unpack('>I',data[4:8])[0]==len(data),'Invalid ICNS'
offset=8;types=set()
while offset<len(data):
 kind=data[offset:offset+4];length=struct.unpack('>I',data[offset+4:offset+8])[0]
 assert length>=8 and offset+length<=len(data),'Invalid icon chunk'
 types.add(kind);offset+=length
assert b'ic10' in types,'Missing 1024px Retina icon'
assert (app/'Contents/Resources/en.lproj/Localizable.strings').is_file(),'Missing English resources'
print('BUNDLE PASS: Finder icon metadata, valid Retina ICNS, English resources')
