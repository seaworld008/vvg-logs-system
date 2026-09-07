#!/usr/bin/env python3
"""Verify Loki wire deduplication against an isolated VictoriaLogs instance."""
import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('renderer', ROOT / 'scripts/render-host-log-collector.py')
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
VECTOR_IMAGE = os.environ.get('VECTOR_IMAGE', 'timberio/vector:0.58.0-alpine')
VL_IMAGE = os.environ.get('VICTORIALOGS_IMAGE', 'victoriametrics/victoria-logs:v1.52.0')


def docker(*args):
    return subprocess.check_output(['docker', *args], stderr=subprocess.STDOUT).decode()


def main():
    name = 'host-label-test-' + uuid.uuid4().hex[:10]
    captured = []

    class Capture(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers['Content-Length']))
            captured.append(body)
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = HTTPServer(('127.0.0.1', 0), Capture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    wire = {}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        (work / 'vl').mkdir()
        try:
            docker('run', '-d', '--name', name + '-vl', '--memory', '512m', '--memory-swap', '512m',
                   '--cpus', '0.5', '--user', '{}:{}'.format(os.getuid(), os.getgid()),
                   '-p', '127.0.0.1::9428', '-v', str(work / 'vl') + ':/data',
                   VL_IMAGE, '-storageDataPath=/data', '-retentionPeriod=1d')
            address = docker('port', name + '-vl', '9428/tcp').strip()
            backend = 'http://' + address
            for attempt in range(50):
                try:
                    with urllib.request.urlopen(backend + '/health', timeout=2) as response:
                        assert response.status == 200
                    break
                except OSError:
                    if attempt == 49:
                        raise
                    time.sleep(0.1)

            for project in ('wangda-app', 'legacy-php'):
                for mode in ('baseline', 'candidate'):
                    cfg = renderer.render_consumer(project)
                    cfg.pop('secret')
                    cfg['data_dir'] = '/tmp/vector-state'
                    cfg['sources'] = {'kafka_vvg': {'type': 'stdin', 'decoding': {'codec': 'json'}}}
                    cfg['sinks'].pop('metrics')
                    sink = cfg['sinks']['victorialogs']
                    sink['endpoint'] = 'http://127.0.0.1:' + str(server.server_port)
                    sink['tenant_id'] = '0:0'
                    if mode == 'baseline':
                        sink['remove_label_fields'] = False
                    assert sink['remove_label_fields'] == (mode == 'candidate')
                    config_path = work / (project + '-' + mode + '.yaml')
                    config_path.write_text(yaml.dump(cfg, Dumper=renderer.Dumper, sort_keys=False), encoding='utf8')
                    events = []
                    bodies = ['plain CLI body', '[ log ] {"code":0,"msg":"\u6210\u529f"}\r\n<xml>body</xml>',
                              'ERROR synthetic stack\n' + '\n'.join('    at example.Main.run(Main.java:42)' for _ in range(9000))]
                    for index, body in enumerate(bodies):
                        events.append({'_automq_event_timestamp': timestamp, 'message': body,
                                       'project': project, 'cluster': project, 'environment': 'test',
                                       'service': 'php_example', 'container': 'php_example',
                                       'instance': 'example-node', 'pod': 'example-node', 'namespace': 'php',
                                       'level': 'error' if index == 2 else 'info', 'file': '/example/runtime/log/a/b/app.log',
                                       'source_offset': index, 'schema_version': '1', 'parse_status': 'plain',
                                       'truncated': False, 'case_id': str(index), 'verification_mode': mode})
                    start = len(captured)
                    result = subprocess.run(['docker', 'run', '--rm', '-i', '--name', name + '-vector',
                                             '--network', 'host', '--memory', '512m', '--memory-swap', '512m',
                                             '--cpus', '0.5', '-v', str(work) + ':/work:ro', VECTOR_IMAGE,
                                             '--config', '/work/' + config_path.name],
                                            input=('\n'.join(json.dumps(e) for e in events) + '\n').encode(),
                                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
                    assert result.returncode == 0, result.stdout.decode()
                    records = {}
                    bodies = captured[start:]
                    assert bodies, 'Loki payload was not emitted'
                    for body in bodies:
                        for stream in json.loads(body)['streams']:
                            for value in stream['values']:
                                event_time, payload = value[:2]
                                event = json.loads(payload)
                                records[event['case_id']] = (stream['stream'], event_time, event, len(payload.encode()), value[2:])
                        request = urllib.request.Request(backend + '/insert/loki/api/v1/push', data=body,
                                                         headers={'Content-Type': 'application/json'})
                        with urllib.request.urlopen(request, timeout=10) as response:
                            assert response.status == 204
                    assert len(records) == len(events)
                    wire[(project, mode)] = records

            for project in ('wangda-app', 'legacy-php'):
                for case, before in wire[(project, 'baseline')].items():
                    after = wire[(project, 'candidate')][case]
                    assert before[:2] == after[:2], 'Stream labels or event time changed'
                    assert before[4] == after[4], 'Structured metadata changed'
                    removed = set(before[0]) - {'job'}
                    assert removed <= set(before[2])
                    assert not removed.intersection(after[2]), 'Stream labels remain in JSON body'
                    expected = {k: v for k, v in before[2].items() if k not in removed}
                    expected['verification_mode'] = 'candidate'
                    assert after[2] == expected, 'Non-label fields changed'
                    assert after[3] < before[3]

            # Query the real decoder, not just a reconstruction of the wire payload.
            rows = []
            for _ in range(50):
                data = urllib.parse.urlencode({'query': '*', 'start': '5m', 'limit': 100}).encode()
                with urllib.request.urlopen(backend + '/select/logsql/query', data=data, timeout=10) as response:
                    rows = [json.loads(line) for line in response.read().splitlines() if line]
                if len(rows) == 12:
                    break
                time.sleep(0.1)
            assert len(rows) == 12, 'Expected both runs for every event'
            indexed = {(r['project'], r['case_id'], r['verification_mode']): r for r in rows}
            for project in ('wangda-app', 'legacy-php'):
                for case in ('0', '1', '2'):
                    before = dict(indexed[(project, case, 'baseline')])
                    after = dict(indexed[(project, case, 'candidate')])
                    before.pop('verification_mode')
                    after.pop('verification_mode')
                    assert before == after, 'Stored fields, body or stream identity changed'
                    assert before['_msg'] and before['_stream'] and before['_stream_id']
                params = urllib.parse.urlencode({'query': 'project:="%s" verification_mode:=candidate '
                                                 'file:="/example/runtime/log/a/b/app.log" | copy _msg as message' % project,
                                                 'start': '5m', 'limit': 10}).encode()
                with urllib.request.urlopen(backend + '/select/logsql/query', data=params, timeout=10) as response:
                    matches = [json.loads(line) for line in response.read().splitlines() if line]
                assert len(matches) == 3 and all(r['message'] == r['_msg'] for r in matches)
            before_bytes = sum(v[3] for (p, m), events in wire.items() if m == 'baseline' for v in events.values())
            after_bytes = sum(v[3] for (p, m), events in wire.items() if m == 'candidate' for v in events.values())
            print('PASS: same labels, stream IDs, timestamps, body, file filters and message alias; '
                  'synthetic JSON payload bytes {} -> {}'.format(before_bytes, after_bytes))
        finally:
            for suffix in ('-vector', '-vl'):
                subprocess.run(['docker', 'rm', '-f', name + suffix], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, check=False)
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == '__main__':
    main()
