#!/usr/bin/env python3
"""Render an explicit host file inventory into the shared Vector/AutoMQ route."""
import argparse
import hashlib
import json
from pathlib import Path
import re

import yaml

ROOT = Path(__file__).resolve().parents[1]
JAVA_HEADER = r'^(?:\{[ \t]*(?:"(?:message|@timestamp|timestamp|level)"[ \t]*:|$)|\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})'
PHP_HEADER = r"^(?:[ \t]*\[[ \t]*\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}|\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}|<xml(?:>|[ \t])|(?:array|Array)[ \t]*\(|'[^\s'])"
SEPARATOR = r'^[ \t]*[-=]{5,}[ \t]*$'
PROJECT_NAMES = {scope['id']:scope['name'] for scope in json.loads(
    (ROOT / 'docker-compose/grafana/project-scopes.json').read_text(encoding='utf-8')) if scope['kind']=='project'}


def project_for_index(index):
    if index.startswith(('jxgl-ptlndx', 'php_jxgl_log')):
        return 'legacy-php'
    return 'wangda-app'


def route_for(spec):
    projects={spec.get('project') or project_for_index(item['legacy_index']) for item in spec['files']}
    if len(projects)!=1:
        raise ValueError('Deploy separate Compose instances and state directories for different projects on one host')
    project=projects.pop()
    environment=spec.get('environment','prod')
    if not re.fullmatch(r'[a-z][a-z0-9-]{1,62}',project) or environment not in ('prod','stage','test','dev'):
        raise ValueError('Invalid stable project ID or environment')
    return {'project':project,'project_name':spec.get('project_name') or PROJECT_NAMES.get(project,project),
            'environment':environment,'topic':f'logs.{environment}.{project}.v1',
            'consumer_group':f'vmlogs.{environment}.{project}.v1',
            'producer_username':f'logs-{environment}-{project}-producer',
            'consumer_username':f'logs-{environment}-{project}-consumer'}


class Dumper(yaml.SafeDumper):
    pass


def text_scalar(dumper, value):
    return dumper.represent_scalar('tag:yaml.org,2002:str', value, style='|' if '\n' in value else None)


Dumper.add_representer(str, text_scalar)


def render(spec, initial=False):
    route=route_for(spec)
    cfg = yaml.safe_load((ROOT / 'docker-compose/vector/host-automq/producer.yaml').read_text(encoding='utf-8'))
    known = set()
    mounts = set()
    for item in spec['files']:
        sid = item['id']
        if not re.fullmatch(r'[a-z][a-z0-9_]*', sid) or sid in known:
            raise ValueError('Source IDs must be unique, stable lowercase identifiers')
        known.add(sid)
        if item['format'] not in ('java', 'php', 'text'):
            raise ValueError('Unsupported format')
        if not item['include'] or not item['mounts']:
            raise ValueError('Explicit source paths and read-only log mounts are required')
        for mount in item['mounts']:
            if not mount.startswith('/') or mount in ('/', '/data', '/etc', '/var', '/usr') or '..' in Path(mount).parts or any(x in mount for x in '*?:\n$'):
                raise ValueError('Mount only explicit log directories')
            mounts.add(mount)
        for path in item['include']:
            if not any(path.startswith(m.rstrip('/') + '/') for m in item['mounts']):
                raise ValueError('Every include must be covered by an explicit mount')
        src = {'type':'file', 'include':item['include'], 'exclude':['**/*.gz','**/*.tmp'],
               'read_from':'end' if initial else 'beginning', 'ignore_checkpoints':False,
               'glob_minimum_cooldown_ms':1000, 'oldest_first':False, 'max_read_bytes':65536,
               'max_line_bytes':16777216, 'rotate_wait_secs':300,
               'fingerprint':{'strategy':'device_and_inode'}, 'offset_key':'source_offset'}
        if item['format'] != 'text':
            pattern = item.get('header', JAVA_HEADER if item['format'] == 'java' else PHP_HEADER)
            boundary = f'(?:{pattern}|{SEPARATOR})' if item['format']=='php' else pattern
            src['multiline'] = {'start_pattern':pattern,'condition_pattern':boundary,'mode':'halt_before','timeout_ms':3000}
        cfg['sources'][sid] = src
        project = route['project']
        language=item.get('language',item['format'])
        service=item['service']
        if language=='php' and not service.startswith('php_'):
            service='php_'+service
        if item.get('legacy_index','').startswith(('jxgl-ptlndx','php_jxgl_log')) and project!='legacy-php':
            raise ValueError('The approved legacy PHP index exceptions must remain in legacy-php')
        fields = {'cluster':project,'project':project,'project_name':route['project_name'],
                  'environment':route['environment'],'service':service,'instance':spec['hostname'],
                  'source_kind':'file','language':language,'log_type':item.get('log_type','application'),'namespace':language,
                  'container':service,'pod':spec['hostname'],
                  'log_format':item['format'],'legacy_index':item.get('legacy_index',''), 'source_id':sid}
        cfg['transforms']['identify_'+sid] = {'type':'remap','inputs':[sid],
            'source':'\n'.join('.'+key+' = '+json.dumps(val,ensure_ascii=False) for key,val in fields.items())+'\n'}
    if not known:
        raise ValueError('At least one log source is required')
    cfg['transforms']['normalize']['inputs'] = ['identify_'+sid for sid in sorted(known)]
    compose = yaml.safe_load((ROOT / 'docker-compose/vector/host-automq/compose.yaml').read_text(encoding='utf-8'))
    compose['services']['vector']['volumes'] += [f'{m}:{m}:ro' for m in sorted(mounts)]
    metrics=spec.get('metrics',{})
    if metrics.get('mode')=='push':
        cfg['sources']['internal_metrics']['scrape_interval_secs']=15
        tags={'project':route['project'],'environment':route['environment'],'pipeline':'host-vvg',
              'job':'vector-host-logs','instance':metrics.get('instance',spec['hostname']),
              'ident':metrics.get('ident',spec['hostname']),'transport':'push'}
        cfg['transforms']['tag_exported_metrics']={'type':'remap','inputs':['internal_metrics'],
            'source':'\n'.join('.tags.'+key+' = '+json.dumps(value) for key,value in tags.items())+'\n'}
        cfg['sinks']['metrics_remote_write']={'type':'prometheus_remote_write','inputs':['tag_exported_metrics'],
            'endpoint':'${METRICS_REMOTE_WRITE_URL}','healthcheck':False,
            'batch':{'max_events':1000,'timeout_secs':1},
            'buffer':{'type':'memory','max_events':1000,'when_full':'block'},
            'request':{'concurrency':1,'timeout_secs':10}}
        compose['services']['vector']['environment']['METRICS_REMOTE_WRITE_URL']='${METRICS_REMOTE_WRITE_URL}'
    return cfg, compose


def render_consumer(project=None):
    cfg = yaml.safe_load((ROOT / 'docker-compose/automq/config/vector-vvg-consumer.yaml').read_text(encoding='utf-8'))
    cfg['sources']['kafka_vvg']['sasl']['username'] = '${AUTOMQ_USERNAME}'
    cfg['sources']['kafka_vvg']['auto_offset_reset'] = 'earliest'
    cfg['transforms']['restore_vvg_event']['source'] += '\n._msg = string!(del(.message))\n'
    if project is not None:
        if not re.fullmatch(r'[a-z][a-z0-9-]{1,62}',project):raise ValueError('Invalid project ID')
        cfg['transforms']['restore_vvg_event']['source'] += '\nassert!(.project == '+json.dumps(project)+', "Project/topic mismatch")\n'
    cfg['sinks']['victorialogs']['labels'] = {
        'job':'host-app', 'cluster':'{{ cluster }}', 'project':'{{ project }}',
        'environment':'{{ environment }}', 'service':'{{ service }}', 'instance':'{{ instance }}',
        'namespace':'{{ namespace }}', 'container':'{{ container }}', 'pod':'{{ pod }}', 'level':'{{ level }}',
    }
    cfg['sinks']['victorialogs']['remove_label_fields'] = True
    return cfg


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('inventory',type=Path)
    p.add_argument('output',type=Path)
    p.add_argument('--initial-tail',action='store_true',help='One-time migration only; restore beginning after checkpoints exist')
    p.add_argument('--project',help='Required project ID for a consumer')
    args=p.parse_args()
    if str(args.inventory) == 'consumer':
        if not args.project:p.error('consumer requires --project')
        cfg=render_consumer(args.project)
        compose=yaml.safe_load((ROOT / 'docker-compose/vector/host-automq/consumer-compose.yaml').read_text(encoding='utf-8'))
        count=1
    else:
        spec=yaml.safe_load(args.inventory.read_text(encoding='utf-8'))
        cfg,compose=render(spec,args.initial_tail)
        count=len(spec['files'])
    args.output.mkdir(parents=True,exist_ok=True)
    for name,data in [('vector.yaml',cfg),('compose.yaml',compose)]:
        (args.output/name).write_text(yaml.dump(data,Dumper=Dumper,allow_unicode=True,sort_keys=False),encoding='utf-8',newline='\n')
    if str(args.inventory)!='consumer':
        (args.output/'route.json').write_text(json.dumps(route_for(spec),ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    hashes=[hashlib.sha256((args.output/n).read_bytes()).hexdigest()+'  '+n for n in ('vector.yaml','compose.yaml')]
    (args.output/'SHA256SUMS').write_text('\n'.join(hashes)+'\n',encoding='ascii')
    print(f'Rendered {count} sources')


if __name__ == '__main__':
    main()
