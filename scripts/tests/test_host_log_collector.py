import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('host_renderer', ROOT / 'scripts/render-host-log-collector.py')
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class HostCollectorTest(unittest.TestCase):
    def test_project_boundary_is_exact(self):
        for name in ('jxgl-ptlndx-2026.09.07','php_jxgl_log-2026.09.07'):
            self.assertEqual(renderer.project_for_index(name),'legacy-php')
        for name in ('php_jxgl-pay-and-more_log','php_appht_lndx_log','java_prod_user','php_activityadmin_log'):
            self.assertEqual(renderer.project_for_index(name),'wangda-app')

    def test_checkpoint_and_rotation_contract(self):
        host={'hostname':'node-01','files':[{'id':'api','service':'api','format':'java',
              'legacy_index':'java_api','include':['/data/apps/api/logs/*.log'],'mounts':['/data/apps/api/logs']}]}
        cfg,compose=renderer.render(host)
        initial,_=renderer.render(host,initial=True)
        self.assertEqual(cfg['sources']['api']['read_from'],'beginning')
        self.assertEqual(initial['sources']['api']['read_from'],'end')
        self.assertFalse(cfg['sources']['api']['ignore_checkpoints'])
        self.assertNotIn('ignore_older_secs',cfg['sources']['api'])
        self.assertEqual(cfg['sources']['api']['fingerprint']['strategy'],'device_and_inode')
        self.assertIn('/data/apps/api/logs:/data/apps/api/logs:ro',compose['services']['vector']['volumes'])
        host['files'][0]['mounts']=['/data']
        with self.assertRaises(ValueError): renderer.render(host)

    def test_consumer_preserves_scope_and_replay(self):
        cfg=renderer.render_consumer()
        self.assertEqual(cfg['sources']['kafka_vvg']['auto_offset_reset'],'earliest')
        self.assertEqual(cfg['sinks']['victorialogs']['labels']['cluster'],'{{ cluster }}')
        self.assertIn('._msg = string!(del(.message))',cfg['transforms']['restore_vvg_event']['source'])
        self.assertEqual(cfg['sinks']['victorialogs']['buffer'],{'type':'memory','max_events':64,'when_full':'block'})

    def test_new_project_names_do_not_change_with_services(self):
        host={'project':'example-project','project_name':'Example Project','environment':'test',
              'hostname':'node-01','files':[{'id':'api','service':'api','format':'java',
              'include':['/data/apps/api/logs/*.log'],'mounts':['/data/apps/api/logs']}]}
        route=renderer.route_for(host)
        self.assertEqual(route['topic'],'logs.test.example-project.v1')
        self.assertEqual(route['consumer_group'],'vmlogs.test.example-project.v1')
        cfg,_=renderer.render(host)
        self.assertIn('.environment = "test"',cfg['transforms']['identify_api']['source'])
        host['files'][0]['legacy_index']='php_jxgl_log'
        with self.assertRaises(ValueError): renderer.render(host)

    def test_mixed_project_inventory_is_rejected(self):
        host={'files':[{'legacy_index':'java_prod_order'},{'legacy_index':'php_jxgl_log'}]}
        with self.assertRaises(ValueError): renderer.route_for(host)

    def test_metrics_push_does_not_change_log_transport(self):
        host={'hostname':'node-01','metrics':{'mode':'push'},'files':[{'id':'api','service':'api','format':'java',
              'legacy_index':'java_api','include':['/data/apps/api/logs/*.log'],'mounts':['/data/apps/api/logs']}]}
        cfg,compose=renderer.render(host)
        self.assertEqual(cfg['sinks']['automq']['inputs'],['drop_formatting_noise'])
        self.assertEqual(cfg['sources']['internal_metrics']['scrape_interval_secs'],15)
        self.assertEqual(cfg['sinks']['metrics_remote_write']['buffer']['type'],'memory')
        self.assertEqual(cfg['sinks']['metrics_remote_write']['request']['concurrency'],1)
        self.assertIn('METRICS_REMOTE_WRITE_URL',compose['services']['vector']['environment'])


if __name__ == '__main__': unittest.main()
