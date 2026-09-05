#!/usr/bin/env bash
set -euo pipefail

kafka_dir=/opt/automq/kafka/bin
client_config=/etc/automq/admin-client.properties

timeout 10 "${kafka_dir}/kafka-broker-api-versions.sh" \
  --bootstrap-server localhost:19092 \
  --command-config "${client_config}" >/dev/null 2>&1

for topic in "${VVG_TOPIC}" "${GATEWAY_TOPIC}"; do
  description="$(timeout 15 "${kafka_dir}/kafka-topics.sh" \
    --bootstrap-server localhost:19092 \
    --command-config "${client_config}" \
    --describe \
    --topic "${topic}" 2>/dev/null)"
  # A summary or warning alone is not evidence of any usable partition.
  awk '
    /Partition:[[:space:]]+[0-9]+/ {
      partitions++
      if ($0 !~ /Leader:[[:space:]]+[0-9]+([[:space:]]|$)/) bad = 1
    }
    END {exit (partitions == 0 || bad)}
  ' <<<"${description}"
done
