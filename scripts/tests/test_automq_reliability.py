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
    def setUp(self):
        super().setUp()
        self.executable("kafka-broker-api-versions.sh", "#!/bin/sh\nexit 99\n")
        self.executable("kafka-topics.sh", '''#!/usr/bin/env python3
import json, os, pathlib, sys
with (pathlib.Path(os.environ["FIXTURE"]) / "calls").open("a") as stream:
    stream.write(json.dumps({"args": sys.argv[1:], "heap": os.environ["KAFKA_HEAP_OPTS"],
                            "jvm": os.environ["KAFKA_JVM_PERFORMANCE_OPTS"]}) + "\\n")
print(os.environ["TOPIC_DESCRIPTION"])
sys.exit(int(os.environ.get("KAFKA_EXIT", "0")))
''')
        self.script = self.directory / "health.sh"
        self.script.write_text((AUTOMQ / "scripts/healthcheck-kafka.sh").read_text()
                          .replace("/opt/automq/kafka/bin", str(self.bin)))
        self.env.update(VVG_TOPIC="vvg.logs.v1", GATEWAY_TOPIC="gateway.access.v1",
                        KAFKA_HEAP_OPTS="-Xms1024m -Xmx1024m",
                        KAFKA_JVM_PERFORMANCE_OPTS="-XX:+UseZGC")

    def topic(self, name):
        return (f"Topic: {name} TopicId: test PartitionCount: 1 ReplicationFactor: 1\n"
                f"Topic: {name} Partition: 0 Leader: 0 Replicas: 0 Isr: 0\n")

    def test_health_requires_both_complete_topics_and_every_leader(self):
        vvg = self.topic("vvg.logs.v1")
        gateway = self.topic("gateway.access.v1")
        valid = vvg + gateway
        for description, healthy in [
            ("", False),
            ("Topic: vvg.logs.v1 PartitionCount: 1 ReplicationFactor: 1", False),
            (vvg, False), (gateway, False), (valid, True),
            (valid.replace("Leader: 0", "Leader: -1", 1), False),
            (valid.replace("Leader: 0", "Leader: none", 1), False),
            (valid.replace("PartitionCount: 1", "PartitionCount: 2", 1), False),
            (valid.replace("Partition: 0", "Partition: 1", 1), False),
            (valid.replace("Partition: 0", "Partition: bad", 1), False),
            (valid + "Topic: vvg.logs.v1 Partition: 0 Leader: 0\n", False),
            (valid.replace("vvg.logs.v1", "vvgXlogsXv1"), False),
            (valid + "Topic: unrelated Partition: 0 Leader: -1\n", True),
        ]:
            with self.subTest(description=description):
                self.env["TOPIC_DESCRIPTION"] = description
                self.assertEqual(self.run_script(self.script).returncode == 0, healthy)

    def test_one_authenticated_bounded_client_without_broker_jvm(self):
        self.env["TOPIC_DESCRIPTION"] = self.topic("vvg.logs.v1") + self.topic("gateway.access.v1")
        result = self.run_script(self.script)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.directory / "calls").read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["heap"], "-Xms32m -Xmx128m")
        self.assertIn("UseSerialGC", calls[0]["jvm"])
        self.assertIn("ActiveProcessorCount=1", calls[0]["jvm"])
        self.assertIn("TieredStopAtLevel=1", calls[0]["jvm"])
        args = calls[0]["args"]
        self.assertIn("--command-config", args)
        self.assertEqual(args[args.index("--topic") + 1], r"^(vvg\.logs\.v1|gateway\.access\.v1)$")

    def test_failed_or_timed_out_query_never_reports_healthy(self):
        self.env["TOPIC_DESCRIPTION"] = self.topic("vvg.logs.v1") + self.topic("gateway.access.v1")
        for code in (1, 124):
            self.env["KAFKA_EXIT"] = str(code)
            self.assertNotEqual(self.run_script(self.script).returncode, 0)

    def test_invalid_or_identical_topic_names_fail_before_query(self):
        for topic in ("", "vvg|other", "vvg$(id)", "gateway.access.v1"):
            self.env["VVG_TOPIC"] = topic
            self.assertNotEqual(self.run_script(self.script).returncode, 0)
        self.assertFalse((self.directory / "calls").exists())


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
    assert "KAFKA_HEAP_OPTS=-Xms32m -Xmx128m" in args
    assert "KAFKA_JVM_PERFORMANCE_OPTS=-XX:+UseSerialGC -XX:ActiveProcessorCount=1" in args
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


class ProducerProgressTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.clock = 1000
        self.state_file = self.directory / "progress"
        self.script = self.directory / "probe.sh"
        self.script.write_text(renderer.PRODUCER_STALL_CHECK_SCRIPT.replace(
            "/tmp/automq-producer-progress", str(self.state_file)))
        self.executable("nc", '#!/bin/sh\nexit "${BROKER_EXIT:-0}"\n')
        self.executable("wget", '#!/bin/sh\ncat "$FIXTURE/metrics"\n')
        self.executable("date", '#!/bin/sh\nprintf "%s\\n" "$NOW"\n')
        self.env.update(AUTOMQ_METRICS_PORT="9598", AUTOMQ_BOOTSTRAP_SERVERS="broker:9092",
                        AUTOMQ_STALL_BUFFER_THRESHOLD_BYTES="67108864")

    def tick(self, lanes, timestamp=True):
        self.env["NOW"] = str(self.clock)
        self.clock += 30
        lines = []
        for lane, queued, sent in lanes:
            for metric, value in (("buffer_size_bytes", queued), ("component_sent_event_bytes_total", sent)):
                suffix = " 123456789" if timestamp else ""
                lines.append(f'vector_{metric}{{component_id="{lane}",component_type="kafka"}} {value}{suffix}')
        (self.directory / "metrics").write_text("\n".join(lines))
        return self.run_script(self.script).returncode

    def test_busy_growing_queue_is_not_a_stall(self):
        for timestamp in (True, False):
            self.state_file.unlink(missing_ok=True)
            self.assertEqual(self.tick([("a", 100000000, 100000000)], timestamp), 0)
            self.assertEqual(self.tick([("a", 800000000, 400000000)], timestamp), 0)

    def test_busy_lane_does_not_hide_slow_or_stuck_lane(self):
        self.assertEqual(self.tick([("a", 100000000, 100000000), ("b", 100000000, 100000000)]), 0)
        self.assertEqual(self.tick([("a", 200000000, 400000000), ("b", 200000000, 100001000)]), 1)
        self.assertEqual(self.tick([("a", 300000000, 700000000), ("b", 300000000, 100001000)]), 1)

    def test_gateway_progress_uses_its_lower_traffic_baseline(self):
        self.env.update(AUTOMQ_STALL_BUFFER_THRESHOLD_BYTES="1048576",
                        AUTOMQ_STALL_MIN_SENT_BYTES_PER_SEC="8192")
        self.assertEqual(self.tick([("gateway", 2000000, 1000000)]), 0)
        self.assertEqual(self.tick([("gateway", 3000000, 2000000)]), 0)
        self.assertEqual(self.tick([("gateway", 4000000, 2001000)]), 1)

    def test_draining_queue_low_queue_and_counter_reset_are_healthy(self):
        self.assertEqual(self.tick([("a", 100000000, 100000000)]), 0)
        self.assertEqual(self.tick([("a", 90000000, 100000000)]), 0)
        self.assertEqual(self.tick([("a", 120000000, 10)]), 0)
        self.assertEqual(self.tick([("a", 100, 10)]), 0)
        self.assertEqual(self.tick([("a", 200, 10)]), 0)

    def test_broker_outage_clears_history_and_missing_metrics_fail(self):
        self.tick([("a", 100000000, 100000000)])
        self.env["BROKER_EXIT"] = "1"
        self.assertEqual(self.tick([("a", 200000000, 100000000)]), 0)
        self.assertFalse(self.state_file.exists())
        self.env["BROKER_EXIT"] = "0"
        self.assertEqual(self.tick([("a", 200000000, 100000000)]), 0)
        self.assertEqual(self.tick([]), 1)


class ManifestTests(unittest.TestCase):
    def test_normal_java_multiline_has_no_fixed_line_split(self):
        for name in ("direct-containerd.yaml", "direct-docker.yaml", "automq-containerd-production.yaml"):
            docs = yaml.safe_load_all((ROOT / "k8s-deployment/vector/vvg" / name).read_text())
            cm = next(d for d in docs if d and d.get("kind") == "ConfigMap")
            config = yaml.safe_load(cm["data"]["vector.yaml"])
            self.assertNotIn("max_events", config["transforms"]["enhance_multiline"])
            self.assertNotIn("end_every_period_ms", config["transforms"]["enhance_multiline"])
            self.assertNotIn("split_vvg_large_event", config["transforms"])

    def test_consumers_budget_worst_case_events_and_inflight_requests(self):
        for pipeline, sink_name, count in (("vvg", "victorialogs", 64), ("gateway", "clickhouse", 16)):
            cfg = yaml.safe_load((AUTOMQ / f"config/vector-{pipeline}-consumer.yaml").read_text())
            sink = cfg["sinks"][sink_name]
            self.assertEqual(sink["buffer"], {"type": "memory", "max_events": count, "when_full": "block"})
            self.assertEqual(sink["request"]["concurrency"], 2)
            self.assertTrue(sink["acknowledgements"]["enabled"])

    def test_large_gateway_fallback_uses_durable_byte_bounded_queue(self):
        docs = yaml.safe_load_all((ROOT / "k8s-deployment/vector/gateway/automq-containerd-production.yaml").read_text())
        cm = next(d for d in docs if d and d.get("kind") == "ConfigMap")
        sink = yaml.safe_load(cm["data"]["vector.yaml"])["sinks"]["clickhouse_oversized_fallback"]
        self.assertEqual(sink["buffer"], {"type": "disk", "max_size": 1073741824, "when_full": "block"})
        self.assertEqual(sink["request"]["concurrency"], 1)
        self.assertEqual(sink["request"]["timeout_secs"], 180)

    def test_pipeline_stall_rates_are_explicit_and_distinct(self):
        for pipeline, expected in (("vvg", "65536"), ("gateway", "8192")):
            docs = yaml.safe_load_all((ROOT / f"k8s-deployment/vector/{pipeline}/automq-containerd-production.yaml").read_text())
            ds = next(d for d in docs if d and d.get("kind") == "DaemonSet")
            env = {e["name"]: e.get("value") for e in ds["spec"]["template"]["spec"]["containers"][0]["env"]}
            self.assertEqual(env["AUTOMQ_STALL_MIN_SENT_BYTES_PER_SEC"], expected)

    def test_native_producer_queues_are_bounded_behind_disk_backpressure(self):
        sink = renderer.kafka_sink(["events"], 5368709120)
        self.assertEqual(sink["librdkafka_options"]["queue.buffering.max.kbytes"], "65536")
        self.assertEqual(sink["buffer"], {"type": "disk", "max_size": 5368709120, "when_full": "block"})
        self.assertEqual(sink["message_timeout_ms"], 0)
        self.assertEqual(sink["librdkafka_options"]["acks"], "all")
        self.assertEqual(sink["compression"], "zstd")

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
