#!/usr/bin/env python3
"""Exercise real Vector file multiline, rotation, normalization and checkpoint replay."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
import yaml

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('renderer',ROOT/'scripts/render-host-log-collector.py')
r=importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
image=os.environ.get('VECTOR_IMAGE','timberio/vector:0.58.0-alpine')
name='host-log-test-'+uuid.uuid4().hex[:10]


def docker(*args):
    return subprocess.check_output(['docker',*args],stderr=subprocess.STDOUT).decode('utf-8')


def rows():
    result=[]
    for line in docker('logs',name).splitlines():
        try: result.append(json.loads(line))
        except json.JSONDecodeError: pass
    return [row for row in result if '_msg' in row]


def wait_rows(count):
    for _ in range(40):
        result=rows()
        if len(result)>=count: return result
        time.sleep(0.5)
    raise AssertionError('Expected events did not arrive')


with tempfile.TemporaryDirectory() as tmp:
    work=Path(tmp)
    (work/'state').mkdir()
    (work/'logs').mkdir()
    for language in ('java','php','text','nginx'):(work/'logs'/language).mkdir()
    inventory={'hostname':'test-node','files':[{'id':'java','service':'api','format':'java','legacy_index':'java_api',
        'include':['/work/logs/java/*.log'],'mounts':['/work/logs']},
        {'id':'php','service':'portal','format':'php','legacy_index':'php_portal_log',
         'include':['/work/logs/php/**/*.log'],'mounts':['/work/logs']},
        {'id':'text','service':'worker','format':'text','legacy_index':'php_worker_log',
         'include':['/work/logs/text/*.log'],'mounts':['/work/logs']},
        {'id':'nginx_site','service':'nginx-site','format':'nginx','namespace':'web','legacy_index':'nginx_site',
         'include':['/work/logs/nginx/*_log'],'mounts':['/work/logs']}]}
    cfg,_=r.render(inventory)
    cfg['data_dir']='/work/state'
    cfg.pop('secret')
    cfg['sources'].pop('internal_metrics')
    cfg['transforms']['backend_message']=r.render_consumer()['transforms']['restore_vvg_event']
    cfg['transforms']['backend_message']['inputs']=['drop_formatting_noise']
    cfg['sinks']={'out':{'type':'console','inputs':['backend_message'],'encoding':{'codec':'json'}}}
    (work/'vector.yaml').write_text(yaml.dump(cfg,Dumper=r.Dumper,sort_keys=False),encoding='utf-8')
    long='2026-09-07 00:00:00 ERROR synthetic stack\n'+'\n'.join('    at example.Main.run(Main.java:42)' for _ in range(9000))
    (work/'logs/java/input.log').write_text(long+'\n',encoding='utf-8')
    php='[ 2026-09-07T00:00:00+08:00 ]\n[ error ] synthetic PHP failure\n    stack frame'
    (work/'logs/php/input.log').write_text(php+'\n',encoding='utf-8')
    (work/'logs/text/input.log').write_text('plain CLI body\n',encoding='utf-8')
    (work/'logs/java/json.log').write_text(json.dumps({'message':'JSON body','level':'INFO','timestamp':'2026-09-07T00:00:00+08:00'})+'\n',encoding='utf-8')
    legacy='2026-09-07 00:00:00 ERROR bad quote "inside"\n    at example.Main.run(Main.java:42)'
    (work/'logs/java/legacy.log').write_text('{"message":"'+legacy+'"}\n',encoding='utf-8')
    stack='2026-09-07 00:00:00 ERROR wrapped stack\njava.lang.Exception: synthetic\n    at example.Main.run(Main.java:42)'
    (work/'logs/java/stack.log').write_text(json.dumps({'message':stack.split('\n')[0]})+'\n'+'\n'.join(stack.split('\n')[1:])+'\n',encoding='utf-8')
    outside='java.lang.Exception: additional stack\n    at example.Other.run(Other.java:9)'
    (work/'logs/java/mixed.log').write_text('{"message":"'+legacy+'"}\n'+outside+'\n',encoding='utf-8')
    php_array="[ 2026-09-07T00:00:00+08:00 ]\n[ log ] array body\narray (\n  'nested' =>\n  array (\n    'status' => 'ok',\n  ),\n)"
    # A root array dump is a separate event; indented nested arrays stay together.
    nested="array (\n  'nested' =>\n  array (\n    'status' => 'ok',\n  ),\n)"
    (work/'logs/php/array.log').write_text(nested+'\n--------------------\n',encoding='utf-8')
    (work/'logs/php/noise.log').write_text('--------------------\n\n====================\n',encoding='utf-8')
    xml="'<xml>\n<code>SUCCESS</code>\n</xml>'"
    (work/'logs/php/xml.log').write_text(xml+'\n--------------------\n',encoding='utf-8')
    (work/'logs/php/a/b/c').mkdir(parents=True)
    deep='[ 2026-09-07T00:00:00+08:00 ] [ info ] deep runtime log'
    (work/'logs/php/a/b/c/deep.log').write_text(deep+'\n',encoding='utf-8')
    # nginx: combined access, JSON access without a message field, and error lines stay one event each.
    combined='10.0.0.8 - - [07/Sep/2026:00:00:00 +0800] "GET /synthetic HTTP/1.1" 502 44 "-" "curl/8"'
    nginx_json=json.dumps({'time':'2026-09-07T00:00:00+08:00','status':404,'request_time':0.125,'uri':'/synthetic'})
    nginx_error='2026/09/07 00:00:00 [crit] 22#22: *1 synthetic upstream failure'
    (work/'logs/nginx/access_log').write_text(combined+'\n'+nginx_json+'\n',encoding='utf-8')
    (work/'logs/nginx/error_log').write_text(nginx_error+'\n',encoding='utf-8')
    try:
        docker('run','-d','--name',name,'--network','none','--memory','512m','--memory-swap','512m',
            '--cpus','1','--user',f'{os.getuid()}:{os.getgid()}','-v',f'{work}:/work',image,'--config','/work/vector.yaml')
        result=wait_rows(13)
        assert sorted(row['_msg'] for row in result)==sorted([long,php,'plain CLI body','JSON body',legacy,stack,nested,xml,legacy+'\n'+outside,deep,combined,nginx_json,nginx_error])
        assert all('message' not in row for row in result), 'Do not store the log body twice'
        assert all(row['cluster']=='wangda-app' for row in result)
        assert next(row for row in result if row['_msg']==php)['level']=='error'
        assert all(row['service'].startswith('php_') for row in result if row['language']=='php')
        nginx={row['_msg']:row for row in result if row['service']=='nginx-site'}
        assert all(row['namespace']=='web' and row['language']=='text' for row in nginx.values())
        assert (nginx[combined]['level'],int(nginx[combined]['http_status']),nginx[combined]['log_type'])==('error',502,'access')
        assert (nginx[nginx_json]['level'],int(nginx[nginx_json]['http_status']),nginx[nginx_json]['time_source'])==('warn',404,'event')
        assert (nginx[nginx_error]['level'],nginx[nginx_error]['log_type'])==('critical','error')
        (work/'logs/java/input.log').rename(work/'logs/java/input.log.1')
        (work/'logs/java/input.log').write_text('2026-09-07 00:01:00 INFO rotated password=synthetic phone=13800138000\n',encoding='utf-8')
        result=wait_rows(14)
        assert 'synthetic' not in result[-1]['_msg'] and '13800138000' not in result[-1]['_msg']
        docker('stop','-t','30',name)
        docker('start',name)
        time.sleep(4)
        assert len(rows())==14, 'Committed source file was reread after restart'
        print('PASS: Java/JSON/PHP/CLI/nginx message mapping, 9000-line event, rotation, redaction and checkpoint')
    finally:
        subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
