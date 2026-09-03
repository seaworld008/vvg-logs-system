#!/usr/bin/env bash
set -euo pipefail

bin=/opt/automq/kafka/bin
bootstrap=automq:19092
admin_config=/etc/automq/admin-client.properties

create_scram_user() {
  local user="$1"
  local password_file="$2"
  local password
  password="$(tr -d '\r\n' < "${password_file}")"
  "${bin}/kafka-configs.sh" --bootstrap-server "${bootstrap}" \
    --command-config "${admin_config}" --alter --entity-type users \
    --entity-name "${user}" \
    --add-config "SCRAM-SHA-512=[iterations=8192,password=${password}]" >/dev/null
}

add_topic_acl() {
  local user="$1"
  local topic="$2"
  shift 2
  "${bin}/kafka-acls.sh" --bootstrap-server "${bootstrap}" \
    --command-config "${admin_config}" --add \
    --allow-principal "User:${user}" --topic "${topic}" "$@" >/dev/null
}

create_scram_user vvg-producer /run/secrets/vvg-producer-password
create_scram_user gateway-producer /run/secrets/gateway-producer-password
create_scram_user vvg-consumer /run/secrets/vvg-consumer-password
create_scram_user gateway-consumer /run/secrets/gateway-consumer-password

"${bin}/kafka-topics.sh" --bootstrap-server "${bootstrap}" \
  --command-config "${admin_config}" --create --if-not-exists \
  --topic "${VVG_TOPIC}" --partitions 12 --replication-factor 1 \
  --config cleanup.policy=delete --config retention.ms=259200000 \
  --config min.insync.replicas=1 --config max.message.bytes=4194304 \
  --config compression.type=producer >/dev/null

"${bin}/kafka-topics.sh" --bootstrap-server "${bootstrap}" \
  --command-config "${admin_config}" --create --if-not-exists \
  --topic "${GATEWAY_TOPIC}" --partitions 6 --replication-factor 1 \
  --config cleanup.policy=delete --config retention.ms=259200000 \
  --config min.insync.replicas=1 --config max.message.bytes=4194304 \
  --config compression.type=producer >/dev/null

add_topic_acl vvg-producer "${VVG_TOPIC}" --operation Write --operation Describe
add_topic_acl gateway-producer "${GATEWAY_TOPIC}" --operation Write --operation Describe

for producer in vvg-producer gateway-producer; do
  "${bin}/kafka-acls.sh" --bootstrap-server "${bootstrap}" \
    --command-config "${admin_config}" --add \
    --allow-principal "User:${producer}" --cluster \
    --operation IdempotentWrite >/dev/null
done

add_topic_acl vvg-consumer "${VVG_TOPIC}" --operation Read --operation Describe
add_topic_acl gateway-consumer "${GATEWAY_TOPIC}" --operation Read --operation Describe

"${bin}/kafka-acls.sh" --bootstrap-server "${bootstrap}" \
  --command-config "${admin_config}" --add \
  --allow-principal User:vvg-consumer --group 'vvg-victorialogs-' \
  --resource-pattern-type prefixed --operation Read >/dev/null
"${bin}/kafka-acls.sh" --bootstrap-server "${bootstrap}" \
  --command-config "${admin_config}" --add \
  --allow-principal User:gateway-consumer --group 'gateway-clickhouse-' \
  --resource-pattern-type prefixed --operation Read >/dev/null

for topic in "${VVG_TOPIC}" "${GATEWAY_TOPIC}"; do
  "${bin}/kafka-topics.sh" --bootstrap-server "${bootstrap}" \
    --command-config "${admin_config}" --describe --topic "${topic}"
done
