#!/usr/bin/env python3
"""Real Vector acceptance for dated replay, deep paths and resume without duplicates."""
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

import yaml

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


r = module('render-host-log-collector')
b = module('render-host-log-backfill')
image = os.environ.get('VECTOR_IMAGE', 'timberio/vector:0.58.0-alpine')
name = 'php-backfill-test-' + uuid.uuid4().hex[:10]


def docker(*args):
    return subprocess.check_output(['docker', *args], stderr=subprocess.STDOUT).decode()


with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    (work / 'state').mkdir()
    today = datetime.now(timezone.utc)
    day = today - timedelta(days=10)
    old = today - timedelta(days=200)
    relative = day.strftime('%Y%m/%d.log')
    rotated = day.strftime('%Y%m/1773903235-%d_cli.log')
    samples = {
        relative: day.strftime('[ %Y-%m-%dT12:00:00+08:00 ]\n[ error ] historical failure\n    frame\n'),
        'pay/deep/' + rotated: "array (\n  'status' => 'ok',\n)\n--------------------\n",
        old.strftime('%Y%m/%d.log'): old.strftime('[ %Y-%m-%dT12:00:00+08:00 ] [ info ] outside retention\n'),
    }
    for path, body in samples.items():
        target = work / 'logs' / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body, encoding='utf-8')
        assert b.file_date('/logs/' + path)
    inventory = {'hostname': 'test-node', 'files': [{'id': 'php', 'service': 'portal', 'format': 'php',
                  'legacy_index': 'php_portal_log', 'include': ['/work/logs/**/*.log'], 'mounts': ['/work/logs']}]}
    live, _ = r.render(inventory)
    cfg = b.replay_config(live, ['php'], 'synthetic-replay', (today - timedelta(days=180)).isoformat())
    assert cfg['transforms']['normalize'] == live['transforms']['normalize']
    cfg['data_dir'] = '/work/state'
    cfg.pop('secret')
    cfg['sinks'] = {'out': {'type': 'console', 'inputs': ['within_retention'], 'encoding': {'codec': 'json'}}}
    (work / 'vector.yaml').write_text(yaml.safe_dump(cfg), encoding='utf-8')

    def rows():
        result = []
        for line in docker('logs', name).splitlines():
            try:
                row = json.loads(line)
                if 'backfill_run' in row:
                    result.append(row)
            except json.JSONDecodeError:
                pass
        return result

    try:
        docker('run', '-d', '--name', name, '--network', 'none', '--memory', '512m', '--memory-swap', '512m',
               '--cpus', '0.5', '--user', f'{os.getuid()}:{os.getgid()}',
               '-v', f'{work}:/work', image, '--config', '/work/vector.yaml')
        for _ in range(45):
            if len(rows()) >= 2:
                break
            time.sleep(1)
        result = rows()
        assert len(result) == 2, docker('logs', name)
        assert {x['time_source'] for x in result} == {'event', 'file_date'}
        assert all(x['source_offset'] == 0 for x in result)
        assert all(x['timestamp'].startswith(day.strftime('%Y-%m-')) for x in result)
        assert any('historical failure\n    frame' in x['message'] for x in result)
        assert all('outside retention' not in x['message'] for x in result)
        docker('stop', '-t', '30', name)
        docker('start', name)
        time.sleep(5)
        assert len(rows()) == 2, 'Replay restart duplicated committed files'
        print('PASS: recursive dated/rotated PHP replay, original offsets, date fallback, retention and resume')
    finally:
        subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
