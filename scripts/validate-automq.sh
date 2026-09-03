#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

mode="${1:---static}"
root=docker-compose/automq
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

require_file() {
  [[ -s "$1" ]] && pass "$2" || fail "$2 ($1 missing or empty)"
}

require_literal() {
  grep -Fq -- "$2" "$1" && pass "$3" || fail "$3"
}

forbid_regex() {
  grep -Eq -- "$2" "$1" && fail "$3" || pass "$3"
}

validate_static() {
  local compose="${root}/docker-compose.yml"
  local env="${root}/env.example"
  local server="${root}/config/server.properties.template"
  local bootstrap="${root}/scripts/bootstrap-cluster.sh"
  local vvg="${root}/config/vector-vvg-consumer.yaml"
  local gateway="${root}/config/vector-gateway-consumer.yaml"

  for file in "${compose}" "${env}" "${server}" "${bootstrap}" \
      "${vvg}" "${gateway}" "${root}/scripts/render-runtime.sh" \
      "${root}/scripts/preflight-kafka.sh" \
      "${root}/scripts/preflight-obs.sh" \
      "${root}/scripts/backup-cce-vector.sh" \
      "${root}/scripts/load-test-kafka.sh" \
      "${root}/scripts/consumer-watchdog.sh" \
      "${root}/scripts/healthcheck-kafka.sh" \
      "${root}/config/automq-consumer-watchdog.service" \
      "${root}/config/automq-consumer-watchdog.timer" \
      "${root}/config/obs-lifecycle.json" \
      "${root}/config/prometheus.yml.template" \
      "${root}/monitoring/nightingale/automq-cluster.json" \
      "scripts/render-automq-vector-manifest.py" \
      "scripts/render-automq-nightingale-dashboard.mjs" \
      "scripts/requirements-automq.txt"; do
    require_file "${file}" "AutoMQ deliverable exists: ${file}"
  done

  require_literal ".gitignore" 'docker-compose/automq/secrets/' \
    "AutoMQ secrets are ignored"
  require_literal ".gitignore" 'docker-compose/automq/runtime/' \
    "Rendered AutoMQ configuration is ignored"
  require_literal "${env}" 'AUTOMQ_IMAGE=registry.example.com/observability/automq:1.7.4@sha256:' \
    "AutoMQ image uses stable 1.7.4 and requires a digest"
  require_literal "${env}" 'VECTOR_IMAGE=registry.example.com/observability/timberio/vector:0.58.0-alpine@sha256:' \
    "AutoMQ consumers pin Vector 0.58.0 by digest"
  forbid_regex "${env}" '(^|[=:])[^#[:space:]]*latest([[:space:]]|$)' \
    "AutoMQ environment has no latest image"
  require_literal "${compose}" 'pull_policy: never' \
    "AutoMQ stack cannot pull images during startup"
  require_literal "${compose}" 'cpus: 3.0' \
    "AutoMQ CPU limit is 3 cores"
  require_literal "${compose}" 'mem_limit: 6g' \
    "AutoMQ memory limit is 6 GiB"
  require_literal "${compose}" 'memswap_limit: 6g' \
    "AutoMQ cannot consume additional swap"
  if [[ "$(grep -Fc 'scale: 3' "${compose}")" == 2 ]] &&
     [[ "$(grep -Fc 'mem_limit: 1536m' "${compose}")" == 2 ]] &&
     [[ "$(grep -Fc 'memswap_limit: 1536m' "${compose}")" == 2 ]]; then
    pass "VVG consumers split 12 partitions across three bounded instances"
  else
    fail "VVG consumers require three 1.5-GiB instances"
  fi
  require_literal "${compose}" 'stop_grace_period: 2m' \
    "AutoMQ has a graceful stop window"
  if [[ "$(grep -Fc 'stop_grace_period: 2m' "${compose}")" -ge 2 ]]; then
    pass "AutoMQ and consumer containers have a two-minute graceful stop window"
  else
    fail "AutoMQ and consumer containers require a two-minute graceful stop window"
  fi
  require_literal "${compose}" '-remoteWrite.basicAuth.usernameFile=/run/secrets/victoriametrics/username' \
    "vmagent reads the VictoriaMetrics username from a secret file"
  require_literal "${compose}" '-remoteWrite.basicAuth.passwordFile=/run/secrets/victoriametrics/password' \
    "vmagent reads the VictoriaMetrics password from a secret file"
  forbid_regex "${compose}" 'remoteWrite\.basicAuth\.(username|password)=' \
    "vmagent Compose contains no inline remote-write credentials"
  require_literal "${server}" 's3.wal.cache.size=524288000' \
    "AutoMQ WAL cache uses the official Tiny value"
  require_literal "${server}" 's3.block.cache.size=104857600' \
    "AutoMQ block cache uses the official Tiny value"
  require_literal "${server}" 's3.wal.upload.threshold=62914560' \
    "AutoMQ upload threshold uses the official Tiny value"
  require_literal "${compose}" '-Xms1024m -Xmx1024m' \
    "AutoMQ heap uses the official Tiny value"
  require_literal "${compose}" '-XX:MaxDirectMemorySize=1536m' \
    "AutoMQ direct memory uses the official Tiny value"
  require_literal "${server}" 's3.data.buckets=0@s3://__AUTOMQ_OBS_BUCKET__' \
    "AutoMQ data uses bucket ID 0"
  require_literal "${server}" 's3.ops.buckets=1@s3://__AUTOMQ_OBS_BUCKET__' \
    "AutoMQ ops uses bucket ID 1 in the approved shared bucket"
  require_literal "${server}" 's3.wal.path=0@s3://__AUTOMQ_OBS_BUCKET__' \
    "AutoMQ WAL reuses bucket ID 0"
  forbid_regex "${server}" 'checksumAlgorithm|accessKey=|secretKey=' \
    "OBS URI has no flexible-checksum override or inline credentials"
  require_literal "${server}" 'SASL_PLAINTEXT' \
    "AutoMQ listener uses approved SASL_PLAINTEXT"
  require_literal "${server}" 'listener.security.protocol.map=CONTROLLER:SASL_PLAINTEXT,EXTERNAL:SASL_PLAINTEXT,INTERNAL:SASL_PLAINTEXT' \
    "All AutoMQ listeners require authentication"
  require_literal "${server}" 'listener.name.controller.plain.sasl.jaas.config=' \
    "Controller listener has an explicit JAAS server and client identity"
  require_literal "${server}" 'listener.name.external.scram-sha-512.sasl.jaas.config=' \
    "External SCRAM listener has an explicit JAAS server configuration"
  require_literal "${server}" 'listener.name.internal.scram-sha-512.sasl.jaas.config=' \
    "Internal SCRAM listener has an explicit JAAS server and client identity"
  require_literal "${server}" 'super.users=User:automq-admin;User:automq_controller' \
    "Only authenticated broker and controller identities bypass ACL checks"
  require_literal "${server}" 'autobalancer.client.listener.name=INTERNAL' \
    "AutoBalancer uses the authenticated internal listener"
  forbid_regex "${server}" 'User:ANONYMOUS|CONTROLLER:PLAINTEXT' \
    "Anonymous controller access is not permitted"
  require_literal "${server}" 'auto.create.topics.enable=false' \
    "AutoMQ disables automatic topic creation"
  require_literal "${bootstrap}" '--partitions 12' \
    "VVG topic has 12 partitions"
  require_literal "${bootstrap}" '--partitions 6' \
    "Gateway topic has 6 partitions"
  if [[ "$(grep -Fc 'retention.ms=259200000' "${bootstrap}")" == 2 ]]; then
    pass "Both AutoMQ topics retain data for 72 hours"
  else
    fail "Both AutoMQ topics must retain data for 72 hours"
  fi
  if [[ "$(grep -Fc 'max.message.bytes=4194304' "${bootstrap}")" == 2 ]]; then
    pass "Both AutoMQ topics enforce the 4 MiB message limit"
  else
    fail "Both AutoMQ topics must enforce the 4 MiB message limit"
  fi
  require_literal "${bootstrap}" 'for topic in "${VVG_TOPIC}" "${GATEWAY_TOPIC}"; do' \
    "Bootstrap validates Kafka 3.9 topics one at a time"
  require_literal "${root}/scripts/preflight-kafka.sh" 'head -c 3000000 /dev/urandom | base64 -w0' \
    "Kafka preflight accepts a 4,000,000-byte boundary record"
  require_literal "${root}/scripts/preflight-kafka.sh" 'head -c 3225000 /dev/urandom | base64 -w0' \
    "Kafka preflight rejects a 4,300,000-byte oversized record"
  require_literal "${root}/scripts/preflight-kafka.sh" 'gateway-producer.properties" --topic "${vvg_topic}' \
    "Kafka preflight includes a cross-topic producer denial test"
  require_literal "${root}/scripts/load-test-kafka.sh" 'events_per_second="${2:-5000}"' \
    "Kafka load gate defaults to at least three times the current event rate"
  require_literal "${root}/scripts/load-test-kafka.sh" 'message.timeout.ms=0' \
    "Kafka load gate does not discard records during transient recovery"
  require_literal "${root}/scripts/consumer-watchdog.sh" '[[ "${failures}" -ge 2 ]]' \
    "Consumer watchdog requires two consecutive inactive checks"
  require_literal "${root}/scripts/consumer-watchdog.sh" 'docker restart -t 120 "${id}" >/dev/null &' \
    "Consumer watchdog restarts group members gracefully and in parallel"
  if python3 - "${root}/scripts/consumer-watchdog.sh" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
assert text.index("vector-gateway-production") < text.index("vector-vvg-production")
PY
  then
    pass "Consumer watchdog prioritizes the production Gateway group"
  else
    fail "Consumer watchdog must check Gateway before VVG"
  fi
  require_literal "${root}/scripts/healthcheck-kafka.sh" "! grep -Eq 'Leader: (-1|none)'" \
    "Broker health requires both business topics to have leaders"
  require_literal "${compose}" 'start_period: 5m' \
    "Broker health allows combined KRaft to recover topic leaders"
  require_literal "${root}/config/automq-consumer-watchdog.timer" 'OnUnitActiveSec=30s' \
    "Consumer watchdog runs every 30 seconds"
  require_literal "${root}/config/automq-consumer-watchdog.timer" 'OnActiveSec=30s' \
    "Consumer watchdog schedules its first run after activation"
  require_literal "${root}/config/obs-lifecycle.json" '"DaysAfterInitiation": 7' \
    "OBS lifecycle aborts incomplete multipart uploads after seven days"
  forbid_regex "${root}/config/obs-lifecycle.json" '"Expiration"[[:space:]]*:' \
    "OBS lifecycle does not delete completed AutoMQ objects"
  require_literal "${root}/scripts/preflight-obs.sh" '-threshold=1048576 -ps=5242880' \
    "OBS preflight forces a multipart upload"
  require_literal "${root}/scripts/preflight-obs.sh" 'sha256sum "${work_dir}/multipart.bin"' \
    "OBS preflight verifies multipart download integrity"
  forbid_regex "${root}/scripts/preflight-obs.sh" 'Access Key Id|Secret Access Key|AKIA|[A-Za-z0-9]{40}' \
    "OBS preflight contains no credential material"
  require_literal "${root}/scripts/backup-cce-vector.sh" 'backup_pipeline vector-log vector-log vector-log-config app=vector-log' \
    "CCE backup stays with the VVG Vector source directory"
  require_literal "${root}/scripts/backup-cce-vector.sh" 'backup_pipeline vector-gateway vector-agent vector-agent-config-v058 app=vector' \
    "CCE backup stays with the Gateway Vector source directory"
  require_literal "${root}/scripts/backup-cce-vector.sh" 'checkpoint_file="${backup_dir}/${daemonset}.checkpoints.sha256"' \
    "CCE backup records checkpoint file hashes"
  require_literal "${bootstrap}" '--operation IdempotentWrite' \
    "Kafka producers receive only the required idempotent-write cluster permission"
  require_literal "${vvg}" 'commit_interval_ms: 1000' \
    "VVG consumer commits offsets every second"
  require_literal "${gateway}" 'commit_interval_ms: 1000' \
    "Gateway consumer commits offsets every second"
  require_literal "${vvg}" 'topic_lag_metric: true' \
    "VVG consumer exports Kafka lag"
  require_literal "${gateway}" 'topic_lag_metric: true' \
    "Gateway consumer exports Kafka lag"
  if [[ "$(grep -Fh 'fetch.max.bytes: "6291456"' "${vvg}" "${gateway}" | wc -l)" == 2 ]] &&
     [[ "$(grep -Fh 'receive.message.max.bytes: "16777216"' "${vvg}" "${gateway}" | wc -l)" == 2 ]] &&
     [[ "$(grep -Fh 'queued.max.messages.kbytes: "4096"' "${vvg}" "${gateway}" | wc -l)" == 2 ]]; then
    pass "Both consumers bound multi-partition fetch and receive memory"
  else
    fail "Both consumers must keep receive.message.max.bytes at least 512 bytes above fetch.max.bytes"
  fi
  if [[ "$(grep -Fh 'metadata.recovery.strategy: rebootstrap' "${vvg}" "${gateway}" | wc -l)" == 2 ]] &&
     [[ "$(grep -Fh 'metadata.recovery.rebootstrap.trigger.ms: "30000"' "${vvg}" "${gateway}" | wc -l)" == 2 ]]; then
    pass "Both consumers use librdkafka rebootstrap recovery within 30 seconds"
  else
    fail "Kafka consumers must explicitly enable bounded rebootstrap recovery"
  fi
  if [[ "$(grep -Fh 'topic.metadata.refresh.sparse: "false"' "${vvg}" "${gateway}" | wc -l)" == 2 ]] &&
     grep -Fq '"topic.metadata.refresh.sparse": "false"' scripts/render-automq-vector-manifest.py; then
    pass "All Kafka clients force complete metadata refreshes after leader loss"
  else
    fail "All Kafka clients must disable sparse metadata refreshes"
  fi
  if [[ "$(grep -Fh 'session_timeout_ms: 120000' "${vvg}" "${gateway}" | wc -l)" == 2 ]] &&
     [[ "$(grep -Fh 'drain_timeout_ms: 30000' "${vvg}" "${gateway}" | wc -l)" == 2 ]]; then
    pass "Both consumers tolerate ordinary broker restarts before group eviction"
  else
    fail "Kafka consumers require the validated session and drain timeouts"
  fi
  if [[ "$(grep -Fh 'fetch.queue.backoff.ms: "100"' "${vvg}" "${gateway}" | wc -l)" == 2 ]] &&
     [[ "$(grep -Fh 'metadata.max.age.ms: "60000"' "${vvg}" "${gateway}" | wc -l)" == 2 ]]; then
    pass "Both consumers use bounded low-queue catch-up tuning"
  else
    fail "Kafka consumers must use the validated catch-up metadata settings"
  fi
  require_literal "${vvg}" 'acknowledgements:' \
    "VVG downstream acknowledgements are enabled"
  require_literal "${gateway}" 'acknowledgements:' \
    "Gateway downstream acknowledgements are enabled"
  require_literal "${vvg}" 'max_events: 500' \
    "VVG memory buffer limits decode amplification"
  require_literal "${gateway}" 'max_events: 5000' \
    "Gateway memory buffer is bounded"
  if [[ "$(grep -Fh 'type: memory' "${vvg}" "${gateway}" | wc -l)" == 2 ]]; then
    pass "Kafka consumers use bounded memory buffers and rely on durable offsets"
  else
    fail "Kafka consumers must use bounded memory buffers"
  fi
  require_literal "${vvg}" 'out_of_order_action: accept' \
    "VVG preserves original event time"
  require_literal "${vvg}" 'healthcheck: false' \
    "VVG consumer matches the production Loki healthcheck behavior"
  require_literal "${gateway}" 'wait_for_processing_timeout: 120' \
    "Gateway keeps ClickHouse async-insert acknowledgement"
  require_literal "${gateway}" 'timeout_secs: 180' \
    "Gateway timeout exceeds ClickHouse async wait"
  require_literal "${root}/monitoring/alert-rules.yml" 'vector_component_errors_total' \
    "Delivery alert uses the exported Vector metric name"
  require_literal "${root}/monitoring/alert-rules.yml" 'vector_kafka_consumer_lag' \
    "Lag alerts use the exported Vector metric name"
  require_literal "${root}/monitoring/alert-rules.yml" 'vector_buffer_size_bytes' \
    "Producer queue alert covers disk buffer size"
  if python3 - "${root}/monitoring/nightingale/automq-cluster.json" <<'PY'
import json, sys
dashboard = json.load(open(sys.argv[1], encoding="utf-8"))
assert dashboard["ident"] == "automq-production-cluster"
panels = dashboard["configs"]["panels"]
assert len(panels) >= 12
assert all(panel["type"] != "unknown" for panel in panels)
assert any("vector_kafka_consumer_lag" in target["expr"] for panel in panels for target in panel["targets"])
assert any("vector_buffer_size_bytes" in target["expr"] for panel in panels for target in panel["targets"])
PY
  then
    pass "Nightingale dashboard uses supported panels and covers lag and producer buffers"
  else
    fail "Nightingale dashboard structure is invalid"
  fi
  forbid_regex "${gateway}" 'requestHeaders|responseHeaders|requestBody|responseBody' \
    "Gateway consumer cannot persist raw headers or bodies"
  require_literal "scripts/requirements-automq.txt" 'PyYAML==6.0.3' \
    "AutoMQ manifest renderer pins PyYAML"
  require_literal "scripts/render-automq-vector-manifest.py" 'length(encode_json(.)) <= 4000000' \
    "VVG routes oversized messages before Kafka"
  require_literal "scripts/render-automq-vector-manifest.py" 'length(encode_json(.)) > 16000000' \
    "VVG separates extreme events that exceed the downstream request limit"
  require_literal "scripts/render-automq-vector-manifest.py" '_automq_original_message_sha256' \
    "VVG preserves an audit hash when an extreme message is truncated"
  if [[ "$(grep -Fc '5368709120' scripts/render-automq-vector-manifest.py)" == 2 ]]; then
    pass "VVG producer uses two 5 GiB parallel disk buffers"
  else
    fail "VVG producer must keep two bounded Kafka lanes"
  fi
  require_literal "scripts/render-automq-vector-manifest.py" 'mod((to_int(xxhash(string!(._automq_partition_key), \"XXH32\")) ?? 0), 2)' \
    "VVG producer deterministically splits events without duplication"
  require_literal "scripts/render-automq-vector-manifest.py" '2147483648' \
    "Gateway producer uses a 2 GiB disk buffer"
  require_literal "scripts/render-automq-vector-manifest.py" '"batch": {"max_bytes": 1048576, "max_events": 500' \
    "Kafka producer batches keep throughput while limiting event-count amplification"
  require_literal "scripts/render-automq-vector-manifest.py" '"message_timeout_ms": 0' \
    "Kafka producer retries indefinitely behind its bounded disk buffer"
  require_literal "scripts/render-automq-vector-manifest.py" 'PRODUCER_STALL_CHECK_SCRIPT' \
    "Kafka producer manifests include a bounded stall detector"
  require_literal "scripts/render-automq-vector-manifest.py" '"failureThreshold": 3' \
    "Kafka producer stall detection requires three consecutive failures"
  require_literal "scripts/render-automq-vector-manifest.py" 'if ! nc -z -w 2' \
    "Kafka producer stall detector does not restart while the broker is unreachable"
  require_literal "scripts/render-automq-vector-manifest.py" '[ "${queued}" -lt "${previous}" ]' \
    "Kafka producer stall detector requires a high queue to drain"
  require_literal "scripts/render-automq-vector-manifest.py" '"mountPath": "/opt/automq-health/producer-stall-check.sh"' \
    "Kafka producer stall detector is mounted as human-readable ConfigMap content"
  require_literal "scripts/render-automq-vector-manifest.py" '"linger.ms": "100"' \
    "Kafka producer uses the AutoMQ throughput linger recommendation"
  require_literal "scripts/render-automq-vector-manifest.py" '"metadata.recovery.strategy": "rebootstrap"' \
    "Kafka producer explicitly recovers from bootstrap metadata"
  require_literal "scripts/render-automq-vector-manifest.py" '%automq_source_file = string(.file)' \
    "Gateway producer preserves the source file in Vector metadata"
  require_literal "scripts/render-automq-vector-manifest.py" 'sink.get("type") == "clickhouse"' \
    "Gateway producer discovers the live structured ClickHouse input"
  forbid_regex "scripts/render-automq-vector-manifest.py" 'requestHeaders|responseHeaders|requestBody|responseBody' \
    "Gateway producer renderer does not copy raw payload fields"
}

validate_vector() {
  local config="$1"
  local port="$2"
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "${temp_dir}"' RETURN
  mkdir -p "${temp_dir}/kafka" "${temp_dir}/clickhouse" "${temp_dir}/data"
  printf 'validation-password\n' > "${temp_dir}/kafka/password"
  printf 'validation-user\n' > "${temp_dir}/clickhouse/username"
  printf 'validation-password\n' > "${temp_dir}/clickhouse/password"
  docker run --rm \
    -e AUTOMQ_BOOTSTRAP_SERVERS=automq.example.internal:9092 \
    -e AUTOMQ_TOPIC=validation-topic \
    -e AUTOMQ_CONSUMER_GROUP=validation-group \
    -e VICTORIALOGS_URL=http://victorialogs.example.internal:9428 \
    -e VICTORIALOGS_TENANT_ID=99:99 \
    -e CLICKHOUSE_URL=http://clickhouse.example.internal:8123 \
    -e CLICKHOUSE_DATABASE=nginxlogs \
    -e CLICKHOUSE_TABLE=nginx_access_automq_shadow \
    -e VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true \
    -v "${repo_root}/${config}:/etc/vector/vector.yaml:ro" \
    -v "${temp_dir}/kafka:/run/secrets/kafka:ro" \
    -v "${temp_dir}/clickhouse:/run/secrets/clickhouse:ro" \
    -v "${temp_dir}/data:/var/lib/vector" \
    timberio/vector:0.58.0-alpine validate --no-environment /etc/vector/vector.yaml
  pass "$(basename "${config}") compiles with Vector 0.58.0 on metrics port ${port}"
  rm -rf -- "${temp_dir}"
  trap - RETURN
}

validate_runtime() {
  local temp_dir
  local rendered
  command -v docker >/dev/null 2>&1 || {
    printf 'docker is required for --runtime validation\n' >&2
    exit 1
  }
  docker compose --env-file "${root}/env.example" \
    -f "${root}/docker-compose.yml" --profile shadow --profile production config --quiet
  pass "AutoMQ Compose expands with both rollout profiles"
  validate_vector "${root}/config/vector-vvg-consumer.yaml" 9598
  validate_vector "${root}/config/vector-gateway-consumer.yaml" 9599

  python3 -c 'import yaml' >/dev/null 2>&1 || {
    printf 'PyYAML from scripts/requirements-automq.txt is required\n' >&2
    exit 1
  }
  temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "${temp_dir}"' RETURN
  for pipeline in vvg gateway; do
    if [[ "${pipeline}" == vvg ]]; then
      source_manifest="k8s-deployment/vector-k8s-containerd-cri.yaml"
    else
      source_manifest="clickhouse-gateway/vector/vector-k8s-containerd.yaml"
    fi
    for rollout_mode in shadow production; do
      rendered="${temp_dir}/${pipeline}-${rollout_mode}.yaml"
      python3 scripts/render-automq-vector-manifest.py \
        --pipeline "${pipeline}" --mode "${rollout_mode}" \
        --input "${source_manifest}" --output "${rendered}" \
        --vector-image 'registry.example.com/observability/timberio/vector:0.58.0-alpine@sha256:732a0051fffd0a402c8a1030f3afc4fa1282cb8b7c992e328e67f0a7cf2e0e45'
      python3 - "${rendered}" "${pipeline}" "${rollout_mode}" <<'PY'
import re, sys, yaml
path, pipeline, mode = sys.argv[1:]
raw = open(path, encoding="utf-8").read()
docs = [d for d in yaml.safe_load_all(raw) if d]
assert [d.get("kind") for d in docs] == ["ConfigMap", "DaemonSet"]
assert "producer-stall-check.sh" in docs[0]["data"]
cfg = yaml.safe_load(docs[0]["data"]["vector.yaml"])
ds = docs[1]
vector = ds["spec"]["template"]["spec"]["containers"][0]
kafka_sinks = [sink for sink in cfg["sinks"].values() if sink.get("type") == "kafka"]
assert all(sink["buffer"]["when_full"] == "block" for sink in kafka_sinks)
assert all(sink["acknowledgements"]["enabled"] is True for sink in kafka_sinks)
assert all(sink["compression"] == "zstd" for sink in kafka_sinks)
assert not re.search(r'^\s+source:\s+"[^"\n]*\\n', raw, re.MULTILINE)
assert ds["spec"]["template"]["spec"]["terminationGracePeriodSeconds"] == 120
assert len(ds["spec"]["template"]["metadata"]["annotations"]["vvg.jinlingkeji.cn/vector-config-sha256"]) == 64
assert "automq-auth" in {v["name"] for v in ds["spec"]["template"]["spec"]["volumes"]}
assert vector["livenessProbe"]["failureThreshold"] == 3
assert vector["livenessProbe"]["periodSeconds"] == 30
assert any(
    mount.get("mountPath") == "/opt/automq-health/producer-stall-check.sh"
    for mount in vector["volumeMounts"]
)
if mode == "shadow":
    assert ds["metadata"]["name"] == f"vector-automq-{pipeline}-shadow"
    assert all(
        source.get("read_from") == "end"
        for source in cfg["sources"].values()
        if source.get("type") in {"file", "kubernetes_logs"}
    )
if pipeline == "vvg":
    assert "victorialogs_oversized" in cfg["sinks"]
    assert len(kafka_sinks) == 2
    assert sum(sink["buffer"]["max_size"] for sink in kafka_sinks) == 10737418240
else:
    assert len(kafka_sinks) == 1
    assert "clickhouse" not in cfg["sinks"]
    assert "clickhouse_auth" in cfg.get("secret", {})
    assert cfg["sinks"]["clickhouse_oversized_fallback"]["inputs"] == ["route_automq_gateway_size.oversized"]
    assert any(v.get("name") == "clickhouse-auth" for v in ds["spec"]["template"]["spec"]["volumes"])
    if mode == "shadow":
        assert "initContainers" not in ds["spec"]["template"]["spec"]
        assert any(
            volume.get("name") == "geoip-data"
            and volume.get("hostPath", {}).get("path") == "/var/lib/vector-gateway"
            for volume in ds["spec"]["template"]["spec"]["volumes"]
        )
print(f"PASS: rendered {pipeline} {mode} producer manifest")
PY
    done
  done
  rm -rf -- "${temp_dir}"
  trap - RETURN
}

case "${mode}" in
  --static) validate_static ;;
  --runtime) validate_static; (( failures == 0 )) && validate_runtime ;;
  *) printf 'Usage: %s [--static|--runtime]\n' "$0" >&2; exit 2 ;;
esac

(( failures == 0 )) || {
  printf '%d AutoMQ validation check(s) failed\n' "${failures}" >&2
  exit 1
}
printf 'AutoMQ validation passed (%s)\n' "${mode}"
