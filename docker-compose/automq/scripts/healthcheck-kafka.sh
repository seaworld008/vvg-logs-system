#!/usr/bin/env bash
set -euo pipefail

kafka_dir=/opt/automq/kafka/bin
client_config=/etc/automq/admin-client.properties

# Short-lived admin clients must not inherit the broker's 1-GiB heap and ZGC.
export KAFKA_HEAP_OPTS='-Xms32m -Xmx128m'
# Metadata probes are short-lived; avoid optimizing them with the C2 compiler.
export KAFKA_JVM_PERFORMANCE_OPTS='-XX:+UseSerialGC -XX:ActiveProcessorCount=1 -XX:TieredStopAtLevel=1'

for topic in "${VVG_TOPIC}" "${GATEWAY_TOPIC}"; do
  [[ "${topic}" =~ ^[A-Za-z0-9._-]+$ ]] || exit 1
done
[[ "${VVG_TOPIC}" != "${GATEWAY_TOPIC}" ]] || exit 1
vvg_pattern="${VVG_TOPIC//./\\.}"
gateway_pattern="${GATEWAY_TOPIC//./\\.}"

# One authenticated metadata request proves API access and both topics' leaders.
description="$(timeout 15 "${kafka_dir}/kafka-topics.sh" \
  --bootstrap-server localhost:19092 \
  --command-config "${client_config}" \
  --describe --topic "^(${vvg_pattern}|${gateway_pattern})$" 2>/dev/null)"
awk -v vvg="${VVG_TOPIC}" -v gateway="${GATEWAY_TOPIC}" '
  {
    topic = ""; partition = ""; leader = ""; count = ""
    for (i = 1; i < NF; i++) {
      if ($i == "Topic:") topic = $(i+1)
      if ($i == "Partition:") partition = $(i+1)
      if ($i == "Leader:") leader = $(i+1)
      if ($i == "PartitionCount:") count = $(i+1)
    }
    if (topic != vvg && topic != gateway) next
    if (count != "") {
      if (count !~ /^[0-9]+$/ || count < 1) bad = 1
      expected[topic] = count
    }
    if (partition != "") {
      if (partition !~ /^[0-9]+$/ || leader !~ /^[0-9]+$/) bad = 1
      if (seen[topic, partition]++) bad = 1
      actual[topic]++
    }
  }
  END {
    required[vvg] = 1; required[gateway] = 1
    for (topic in required) {
      if (!expected[topic] || actual[topic] != expected[topic]) bad = 1
      for (p = 0; p < expected[topic]; p++) if (!seen[topic, p]) bad = 1
    }
    exit (bad ? 1 : 0)
  }
' <<<"${description}"
