import copy
from datetime import date
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


b = load('render-host-log-backfill')
r = load('render-host-log-collector')


class BackfillTest(unittest.TestCase):
    def test_real_rotation_names_and_invalid_dates(self):
        for name in ['19.log', '19_cli.log', '1773903235-19_cli.log', 'nocallback_19.log']:
            self.assertEqual(b.file_date('/logs/pay/2026/202603/' + name), date(2026, 3, 19))
        for path in ['/logs/202602/31.log', '/logs/unknown.log', '/logs/202603/19.log.gz']:
            with self.assertRaises(ValueError):
                b.file_date(path)

    def test_live_recovery_and_normalization_are_unchanged(self):
        live, _ = r.render({'hostname': 'example', 'files': [{'id': 'php', 'service': 'portal',
            'format': 'php', 'legacy_index': 'php_portal', 'include': ['/logs/**/*.log'], 'mounts': ['/logs']}]})
        original = copy.deepcopy(live)
        replay = b.replay_config(live, ['php'], 'example-backfill', '2026-03-12T08:00:00Z')
        self.assertEqual(live, original)
        self.assertEqual(replay['transforms']['normalize'], live['transforms']['normalize'])
        self.assertEqual(replay['sources']['php']['include'], ['/logs/**/*.log'])
        self.assertFalse(replay['sources']['php']['ignore_checkpoints'])
        self.assertEqual(replay['sources']['php']['fingerprint'], live['sources']['php']['fingerprint'])
        self.assertNotIn('metrics_remote_write', replay['sinks'])
        self.assertNotIn('backfill_run', replay['sinks']['automq'].get('labels', {}))


if __name__ == '__main__':
    unittest.main()
