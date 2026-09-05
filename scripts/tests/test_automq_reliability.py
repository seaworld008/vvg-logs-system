"""Offline regressions for startup, recovery and live-manifest conversion.

Only external Kafka/Docker commands are simulated; shell control flow, counters,
configuration parsing and manifest generation run from the repository scripts.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
AUTOMQ = ROOT / "docker-compose/automq"
spec = importlib.util.spec_from_file_location(
    "automq_renderer", ROOT / "scripts/render-automq-vector-manifest.py"
)
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class ShellFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "FIXTURE": str(self.directory)}

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)
        return path

    def run_script(self, path):
        return subprocess.run(["bash", str(path)], env=self.env,
                              capture_output=True, text=True, timeout=10)


class BootstrapTests(ShellFixture):
    def test_remote_consumers_never_pull_images_on_startup(self):
        services = yaml.safe_load((AUTOMQ / "docker-compose.vvg-consumers.yml").read_text())["services"]
        for name, service in services.items():
            with self.subTest(service=name):
                self.assertEqual(service.get("pull_policy"), "never")

    def test_bootstrap_can_run_before_topics_are_healthy(self):
        services = yaml.safe_load((AUTOMQ / "docker-compose.yml").read_text())["services"]
        self.assertEqual(services["automq-bootstrap"]["depends_on"]["automq"]["condition"],
                         "service_started", "Topic creation must not wait for topic health")
        for name, service in services.items():
            if name.startswith("vector-"):
                self.assertEqual(service["depends_on"]["automq"]["condition"], "service_healthy")

    def prepare_bootstrap(self, failed_attempts):
        self.env.update(VVG_TOPIC="vvg.logs.v1", GATEWAY_TOPIC="gateway.access.v1",
                        FAILED_ATTEMPTS=str(failed_attempts))
        secrets = self.directory / "secrets"
        secrets.mkdir()
        for name in ("vvg-producer", "gateway-producer", "vvg-consumer", "gateway-consumer"):
            (secrets / f"{name}-password").write_text("test-password")
        command = '''#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE"])
name = pathlib.Path(sys.argv[0]).name
if name == "kafka-broker-api-versions.sh":
    count = root / "attempts"
    attempt = int(count.read_text()) + 1 if count.exists() else 1
    count.write_text(str(attempt))
    sys.exit(1 if attempt <= int(os.environ["FAILED_ATTEMPTS"]) else 0)
with (root / "mutations").open("a") as stream:
    stream.write(name + "\\n")
'''
        for name in ("kafka-broker-api-versions.sh", "kafka-configs.sh", "kafka-topics.sh", "kafka-acls.sh"):
            self.executable(name, command)
        self.executable("sleep", "#!/bin/sh\nexit 0\n")
        script = self.directory / "bootstrap.sh"
        script.write_text((AUTOMQ / "scripts/bootstrap-cluster.sh").read_text()
                          .replace("/opt/automq/kafka/bin", str(self.bin))
                          .replace("/run/secrets", str(secrets)))
        return script

    def test_bootstrap_retries_api_before_mutating_cluster(self):
        result = self.run_script(self.prepare_bootstrap(2))
        self.assertEqual(result.returncode, 0, result.stderr)
        attempts = self.directory / "attempts"
        self.assertTrue(attempts.exists(), "Bootstrap never probed the Kafka API")
        self.assertEqual(attempts.read_text(), "3")
        self.assertTrue((self.directory / "mutations").exists())

    def test_bootstrap_fails_without_mutations_when_api_never_ready(self):
        result = self.run_script(self.prepare_bootstrap(1000))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / "mutations").exists())


class HealthTests(ShellFixture):
    def test_health_requires_partition_rows_and_every_leader(self):
        self.executable("kafka-broker-api-versions.sh", "#!/bin/sh\nexit 0\n")
        self.executable("kafka-topics.sh", '#!/bin/sh\nprintf "%s\\n" "$TOPIC_DESCRIPTION"\n')
        script = self.directory / "health.sh"
        script.write_text((AUTOMQ / "scripts/healthcheck-kafka.sh").read_text()
                          .replace("/opt/automq/kafka/bin", str(self.bin)))
        self.env.update(VVG_TOPIC="vvg.logs.v1", GATEWAY_TOPIC="gateway.access.v1")
        for description, healthy in [
            ("", False),
            ("Topic: vvg.logs.v1 PartitionCount: 1 ReplicationFactor: 1", False),
            ("Topic: vvg.logs.v1 Partition: 0 Leader: -1 Replicas: 0 Isr:", False),
            ("Topic: vvg.logs.v1 Partition: 0 Leader: none Replicas: 0 Isr:", False),
            ("Topic: vvg.logs.v1 Partition: 0 Leader: 0 Replicas: 0 Isr: 0", True),
            ("Topic: vvg.logs.v1 Partition: 0 Leader: 0 Replicas: 0 Isr: 0\n"
             "Topic: vvg.logs.v1 Partition: 1 Leader: -1 Replicas: 0 Isr:", False),
        ]:
            with self.subTest(description=description):
                self.env["TOPIC_DESCRIPTION"] = description
                self.assertEqual(self.run_script(script).returncode == 0, healthy)


class WatchdogTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.env["AUTOMQ_DIR"] = str(self.directory)
        (self.directory / ".env").write_text(
            "VVG_CONSUMER_GROUP=vvg-victorialogs-shadow-v1\n"
            "GATEWAY_CONSUMER_GROUP=gateway-clickhouse-shadow-v1\n"
        )
        self.scenario = {"healthy": True, "services": {
            "vector-gateway-production": ["gateway-1"],
            "vector-vvg-production": ["vvg-1", "vvg-2"]}, "groups": {}}
        self.executable("docker", '''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE"])
state = json.loads((root / "scenario.json").read_text())
args = sys.argv[1:]
if args[0] == "inspect":
    print("healthy" if state["healthy"] else "unhealthy")
elif args[0] == "ps":
    service = next(a.split("=", 2)[-1] for a in args if a.startswith("label=com.docker.compose.service="))
    ids = state["services"].get(service, [])
    if "label=com.docker.compose.project=automq" not in args:
        ids = ids + state.get("foreign_services", {}).get(service, [])
    print("\\n".join(ids))
elif args[0] == "exec":
    group = args[args.index("--group") + 1]
    with (root / "queries").open("a") as stream:
        stream.write(group + "\\n")
    value = state["groups"].get(group, "empty")
    if value == "error":
        sys.exit(1)
    if value == "malformed":
        print("unexpected output")
    elif "--state" in args:
        print("\\nGROUP COORDINATOR (ID) ASSIGNMENT-STRATEGY STATE #MEMBERS")
        print(group + " automq:19092 (0) range " + ("Stable 2" if value == "active" else "Empty 0"))
    else:
        print("\\nGROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG CONSUMER-ID HOST CLIENT-ID")
        print(group + " vvg.logs.v1 0 10 10 0 " + ("member /host vector" if value == "active" else "- - -"))
elif args[0] == "restart":
    with (root / "restarts").open("a") as stream:
        stream.write(args[-1] + "\\n")
else:
    sys.exit(2)
''')

    def tick(self):
        (self.directory / "scenario.json").write_text(json.dumps(self.scenario))
        result = self.run_script(AUTOMQ / "scripts/consumer-watchdog.sh")
        self.assertEqual(result.returncode, 0, result.stderr)

    def restarted(self):
        path = self.directory / "restarts"
        return sorted(path.read_text().splitlines()) if path.exists() else []

    def test_restart_only_after_two_successful_empty_observations(self):
        self.tick()
        self.assertEqual(self.restarted(), [])
        self.tick()
        self.assertEqual(self.restarted(), ["gateway-1", "vvg-1", "vvg-2"])

    def test_query_error_does_not_block_other_group_recovery(self):
        self.scenario["groups"]["gateway-clickhouse-production-v1"] = "error"
        self.tick()
        self.tick()
        self.assertEqual(self.restarted(), ["vvg-1", "vvg-2"])

    def test_unknown_or_broker_down_breaks_consecutive_failure_count(self):
        for interruption in ("error", "malformed", "broker-down"):
            with self.subTest(interruption=interruption):
                self.scenario["groups"] = {}
                self.tick()
                if interruption == "broker-down":
                    self.scenario["healthy"] = False
                else:
                    self.scenario["groups"] = {group: interruption for group in
                        ("gateway-clickhouse-production-v1", "vvg-victorialogs-production-v1")}
                self.tick()
                self.scenario["healthy"] = True
                self.scenario["groups"] = {}
                self.tick()
                self.assertEqual(self.restarted(), [])
                self.scenario["groups"] = {group: "active" for group in
                    ("gateway-clickhouse-production-v1", "vvg-victorialogs-production-v1")}
                self.tick()

    def test_other_compose_project_does_not_hide_local_shadow(self):
        self.scenario["services"] = {"vector-vvg-shadow": ["shadow-1"]}
        self.scenario["foreign_services"] = {"vector-vvg-production": ["foreign-1"]}
        self.tick()
        self.tick()
        self.assertEqual(self.restarted(), ["shadow-1"])

    def test_dotenv_is_data_and_never_executes_shell(self):
        marker = self.directory / "must-not-exist"
        with (self.directory / ".env").open("a") as stream:
            stream.write(f"UNRELATED_VALUE=$(touch {marker})\n")
        self.tick()
        self.assertFalse(marker.exists(), "watchdog executed .env as shell code")


class ManifestTests(unittest.TestCase):
    def config(self):
        docs = yaml.safe_load_all((ROOT / "k8s-deployment/vector/vvg/direct-containerd.yaml").read_text())
        return yaml.safe_load(next(d for d in docs if d.get("kind") == "ConfigMap")["data"]["vector.yaml"])

    def test_vvg_preserves_live_sink_inputs_and_auxiliary_sinks(self):
        config = self.config()
        config["transforms"]["site_redaction"] = {
            "type": "remap", "inputs": ["add_msg_field"], "source": "del(.token)"}
        config["sinks"]["victorialogs"]["inputs"] = ["site_redaction"]
        config["sinks"]["site_diagnostics"] = {
            "type": "blackhole", "inputs": ["site_redaction"]}
        for mode in ("shadow", "production"):
            with self.subTest(mode=mode):
                output = yaml.safe_load(renderer.render_vector_config(yaml.safe_dump(config), "vvg", mode))
                self.assertEqual(output["transforms"]["prepare_automq_event"]["inputs"], ["site_redaction"])
                self.assertEqual(output["sinks"]["site_diagnostics"], config["sinks"]["site_diagnostics"])

    def test_vvg_rejects_missing_live_sink_inputs(self):
        config = self.config()
        config["sinks"]["victorialogs"]["inputs"] = []
        with self.assertRaises(SystemExit):
            renderer.render_vector_config(yaml.safe_dump(config), "vvg", "production")


if __name__ == "__main__":
    unittest.main()
