#!/usr/bin/env python3
"""Install checksum-pinned gaze models for local evaluation."""
import hashlib
import json
from pathlib import Path
import urllib.request

root=Path(__file__).resolve().parent.parent/'Assets/models'
manifest=json.loads((root/'neural-manifest.json').read_text())
for name,entry in manifest['files'].items():
    path=root/name
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest()!=entry['sha256']:
        data=urllib.request.urlopen(entry['url'],timeout=60).read()
        if hashlib.sha256(data).hexdigest()!=entry['sha256']: raise ValueError(f'Checksum mismatch: {name}')
        temp=path.with_suffix('.download');temp.write_bytes(data);temp.replace(path)
    print(f'{name}: verified')
