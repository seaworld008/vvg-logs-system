#!/usr/bin/env python3
"""One-time Vector 0.58 file-source migration cutoff for existing files only."""
import argparse
from datetime import datetime, timezone
import glob
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def seed(inventory, state):
    total=0
    for source in inventory['files']:
        sid=source['id']
        if not re.fullmatch(r'[a-z][a-z0-9_]*',sid): raise ValueError('Invalid source ID')
        path=state/sid/'checkpoints.json'
        data=json.loads(path.read_text(encoding='utf-8'))
        if data.get('version')!='1' or not isinstance(data.get('checkpoints'),list):
            raise ValueError('Unsupported Vector checkpoint format')
        seen={tuple(entry['fingerprint']['dev_inode']) for entry in data['checkpoints']}
        added=0
        for pattern in source['include']:
            for name in glob.iglob(pattern,recursive=True):
                if name.endswith(('.gz','.tmp')) or not os.path.isfile(name): continue
                stat=os.stat(name)
                key=(stat.st_dev,stat.st_ino)
                if key in seen: continue
                data['checkpoints'].append({'fingerprint':{'dev_inode':list(key)},'position':stat.st_size,
                    'modified':datetime.now(timezone.utc).isoformat().replace('+00:00','Z')})
                seen.add(key)
                added+=1
        if added:
            backup=path.with_name('checkpoints.pre-migration.json')
            if backup.exists(): raise ValueError('Checkpoint cutoff already applied; inspect before retrying')
            shutil.copy2(path,backup)
            candidate=path.with_suffix('.candidate')
            with candidate.open('x',encoding='utf-8') as f:
                json.dump(data,f,separators=(',',':'))
                f.flush()
                os.fsync(f.fileno())
            os.replace(candidate,path)
        total+=added
    return total


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('inventory',type=Path,help='Reviewed JSON inventory matching the initial-tail configuration')
    p.add_argument('state',type=Path)
    p.add_argument('--container',required=True)
    args=p.parse_args()
    running=subprocess.check_output(['docker','inspect','--format','{{.State.Running}}',args.container],text=True).strip()
    if running!='false': raise SystemExit('Stop this Vector container before changing its checkpoints')
    print('Seeded existing-file EOF checkpoints:',seed(json.loads(args.inventory.read_text(encoding='utf-8')),args.state))
