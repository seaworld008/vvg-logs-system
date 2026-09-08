#!/usr/bin/env python3
"""Render an isolated PHP replay from the reviewed live config and frozen log copies.

The caller mounts immutable copies at the ORIGINAL log paths and supplies a new,
empty state directory. Never mount or reset the live collector's state.
"""
import argparse
import copy
from datetime import datetime
import json
from pathlib import Path
import re

import yaml


def file_date(path):
    # ThinkPHP ordinary and size-rotated files: YYYYMM/DD[_cli].log or epoch-DD.
    match = re.search(r'/(20\d{2}[01]\d)/(?:\d{10}-|nocallback_)?([0-3]\d)(?:_[^/]*)?\.log$', path)
    if not match:
        raise ValueError('Unrecognized log date: ' + path)
    return datetime.strptime(match[1] + match[2], '%Y%m%d').date()


def replay_config(live, source_ids, run_id, earliest):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,63}', run_id):
        raise ValueError('Invalid run ID')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})', earliest):
        raise ValueError('Earliest must be an explicit RFC3339 timestamp')
    datetime.strptime(earliest[:19], '%Y-%m-%dT%H:%M:%S')
    cfg = copy.deepcopy(live)
    cfg['sources'] = {sid: cfg['sources'][sid] for sid in source_ids}
    for sid, source in cfg['sources'].items():
        if source['type'] != 'file' or 'multiline' not in source:
            raise ValueError('Replay requires a reviewed PHP multiline file source')
        source.update(read_from='beginning', ignore_checkpoints=False,
                      oldest_first=True, glob_minimum_cooldown_ms=60000)
        source.pop('ignore_older_secs', None)
    keep = ['identify_' + sid for sid in source_ids] + ['normalize', 'drop_formatting_noise']
    cfg['transforms'] = {key: cfg['transforms'][key] for key in keep}
    cfg['transforms']['normalize']['inputs'] = ['identify_' + sid for sid in source_ids]
    # Keep live normalization/redaction/size guards byte-for-byte. Date fallback
    # is specific to replay so undated historical output cannot become "now".
    cfg['transforms']['date_backfill'] = {
        'type': 'remap', 'inputs': ['drop_formatting_noise'], 'drop_on_error': True,
        'source': r'''
if .time_source == "ingest" {
  parts = parse_regex!(string!(.file), r'/(?P<month>20\d{2}[01]\d)/(?:\d{10}-|nocallback_)?(?P<day>[0-3]\d)(?:_[^/]*)?\.log$')
  day = parts.month + parts.day
  .timestamp = parse_timestamp!(day + " 00:00:00", "%Y%m%d %H:%M:%S", timezone: "Asia/Shanghai")
  .time_source = "file_date"
}
._automq_event_timestamp = format_timestamp!(.timestamp, "%+")
.backfill_run = ''' + json.dumps(run_id) + '\n'}
    cfg['transforms']['within_retention'] = {
        'type': 'filter', 'inputs': ['date_backfill'],
        'condition': 'timestamp!(.timestamp) >= parse_timestamp!(' + json.dumps(earliest) + ', "%+") && timestamp!(.timestamp) <= now()'}
    cfg['sources']['internal_metrics'] = {'type': 'internal_metrics'}
    cfg['sinks'] = {key: cfg['sinks'][key] for key in ('automq', 'metrics')}
    cfg['sinks']['automq']['inputs'] = ['within_retention']
    cfg['sinks']['metrics']['inputs'] = ['internal_metrics']
    return cfg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('live_config', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--source', action='append', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--earliest', required=True)
    args = parser.parse_args()
    cfg = replay_config(yaml.safe_load(args.live_config.read_text(encoding='utf-8')),
                        args.source, args.run_id, args.earliest)
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        yaml.safe_dump(cfg, stream, allow_unicode=True, sort_keys=False)


if __name__ == '__main__':
    main()
