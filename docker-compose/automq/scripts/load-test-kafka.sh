#!/usr/bin/env bash
set -euo pipefail

duration_seconds="${1:-1800}"
events_per_second="${2:-5000}"
topic="${VVG_TOPIC:-vvg.logs.v1}"
bootstrap="${AUTOMQ_TEST_BOOTSTRAP:-automq:19092}"
bin=/opt/automq/kafka/bin
work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
chmod 0700 "${work_dir}"

[[ "${duration_seconds}" =~ ^[1-9][0-9]*$ ]]
[[ "${events_per_second}" =~ ^[1-9][0-9]*$ ]]
records=$((duration_seconds * events_per_second))
password="$(tr -d '\r\n' < /run/secrets/vvg-producer-password)"
umask 077
cat > "${work_dir}/producer.properties" <<EOF
bootstrap.servers=${bootstrap}
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="vvg-producer" password="${password}";
acks=all
enable.idempotence=true
compression.type=zstd
message.timeout.ms=0
max.request.size=4194304
EOF
unset password

timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
padding="$(head -c 400 /dev/zero | tr '\0' x)"
printf '{"_automq_event_timestamp":"%s","_automq_partition_key":"load-test","timestamp":"%s","message":"automq-3x-load-%s","_msg":"automq-3x-load-%s","level":"info","kubernetes":{"pod_namespace":"automq-preflight","pod_name":"load-test","container_name":"load-test"}}\n' \
  "${timestamp}" "${timestamp}" "${padding}" "${padding}" > "${work_dir}/payload.jsonl"

"${bin}/kafka-producer-perf-test.sh" \
  --topic "${topic}" \
  --num-records "${records}" \
  --throughput "${events_per_second}" \
  --payload-file "${work_dir}/payload.jsonl" \
  --producer.config "${work_dir}/producer.properties" \
  --print-metrics
