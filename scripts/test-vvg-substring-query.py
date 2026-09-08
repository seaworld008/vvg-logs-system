#!/usr/bin/env python3
"""Validate quoted literal substring semantics against an isolated VictoriaLogs."""
from datetime import datetime, timezone
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request
import uuid

name = 'vvg-substring-test-' + uuid.uuid4().hex[:10]
image = os.environ.get('VICTORIALOGS_IMAGE', 'victoriametrics/victoria-logs:v1.52.0')


def docker(*args):
    return subprocess.check_output(['docker', *args], stderr=subprocess.STDOUT).decode().strip()


try:
    docker('run', '-d', '--name', name, '--memory', '512m', '--memory-swap', '512m', '--cpus', '1',
           '-p', '127.0.0.1::9428', image, '-storageDataPath=/tmp/test-logs', '-retentionPeriod=1d')
    port = json.loads(docker('inspect', name))[0]['NetworkSettings']['Ports']['9428/tcp'][0]['HostPort']
    url = 'http://127.0.0.1:' + port
    for _ in range(30):
        try:
            urllib.request.urlopen(url + '/health', timeout=2).read()
            break
        except OSError:
            time.sleep(0.5)
    values = ['海康门闸入参', '前缀海康同步异常', '其他消息', 'a.*[0](x)', 'literal*star', 'C:\\logs\\file.log',
              '" OR * | stats count()']
    payload = b'\n'.join(json.dumps({'_time': datetime.now(timezone.utc).isoformat(), '_msg': value,
                                     'sample_id': str(index)}, ensure_ascii=False).encode()
                          for index, value in enumerate(values))
    urllib.request.urlopen(urllib.request.Request(url + '/insert/jsonline?_msg_field=_msg&_time_field=_time',
                           data=payload, headers={'Content-Type': 'application/stream+json'}), timeout=10).read()

    def query(expression):
        body = urllib.parse.urlencode({'query': expression + ' | fields sample_id', 'limit': 100}).encode()
        raw = urllib.request.urlopen(urllib.request.Request(url + '/select/logsql/query', data=body), timeout=10).read()
        return {int(json.loads(line)['sample_id']) for line in raw.splitlines() if line}

    for _ in range(30):
        if len(query('*')) == len(values):
            break
        time.sleep(0.5)
    assert len(query('*')) == len(values), 'Synthetic insertion did not become queryable'
    assert query('_msg:"海康"') == set()
    for term in ['海康', '康门', 'a.*[0](x)', '*', 'C:\\logs\\file.log', '" OR * | stats count()']:
        encoded = json.dumps(term, ensure_ascii=False)
        expected = {index for index, value in enumerate(values) if term in value}
        actual = query('_msg:*' + encoded + '*')
        assert actual == expected, (term, actual, expected)
        assert query('-_msg:*' + encoded + '*') == set(range(len(values))) - expected, term
    assert query('_msg:*"海康"* _msg:*"门闸"*') == {0}
    assert query('(_msg:*"门闸"* OR _msg:*"同步"*)') == {0, 1}
    print('PASS: Chinese infix, AND/OR/NOT, quoted wildcard, regex punctuation, path and injection text')
finally:
    subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
