#!/usr/bin/env bash
set -euo pipefail

bin=/opt/automq/kafka/bin
bootstrap="${AUTOMQ_TEST_BOOTSTRAP:-127.0.0.1:9092}"
vvg_topic="${VVG_TOPIC:-vvg.logs.v1}"
gateway_topic="${GATEWAY_TOPIC:-gateway.access.v1}"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
chmod 0700 "${work_dir}"

client_config() {
  local user="$1"
  local password_file="$2"
  local output="$3"
  local password
  password="$(tr -d '\r\n' < "${password_file}")"
  umask 077
  cat > "${output}" <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="${user}" password="${password}";
request.timeout.ms=10000
delivery.timeout.ms=30000
max.request.size=5242880
acks=all
compression.type=none
EOF
}

client_config vvg-producer /run/secrets/vvg-producer-password "${work_dir}/vvg-producer.properties"
client_config gateway-producer /run/secrets/gateway-producer-password "${work_dir}/gateway-producer.properties"
client_config vvg-consumer /run/secrets/vvg-consumer-password "${work_dir}/vvg-consumer.properties"
client_config gateway-consumer /run/secrets/gateway-consumer-password "${work_dir}/gateway-consumer.properties"

printf '{"automq_preflight":"authorized-small"}\n' |
  "${bin}/kafka-console-producer.sh" --bootstrap-server "${bootstrap}" \
    --producer.config "${work_dir}/vvg-producer.properties" --topic "${vvg_topic}" \
    >"${work_dir}/authorized-producer.log" 2>&1

timeout 20 "${bin}/kafka-console-consumer.sh" --bootstrap-server "${bootstrap}" \
  --consumer.config "${work_dir}/vvg-consumer.properties" --topic "${vvg_topic}" \
  --group vvg-victorialogs-preflight --from-beginning --max-messages 1 \
  > /dev/null 2>"${work_dir}/authorized-consumer.log"
printf 'PASS: authorized producer and consumer use the external listener\n'

set +e
printf '{"automq_preflight":"must-be-denied"}\n' |
  "${bin}/kafka-console-producer.sh" --bootstrap-server "${bootstrap}" \
    --producer.config "${work_dir}/gateway-producer.properties" --topic "${vvg_topic}" \
    >"${work_dir}/denied-producer.log" 2>&1
producer_rc=$?
timeout 15 "${bin}/kafka-console-consumer.sh" --bootstrap-server "${bootstrap}" \
  --consumer.config "${work_dir}/gateway-consumer.properties" --topic "${vvg_topic}" \
  --group gateway-clickhouse-preflight --from-beginning --max-messages 1 \
  > /dev/null 2>"${work_dir}/denied-consumer.log"
consumer_rc=$?
set -e

grep -Eq 'TopicAuthorizationException|not authorized|Not authorized' "${work_dir}/denied-producer.log" || {
  printf 'FAIL: cross-topic producer was not explicitly denied (exit=%s)\n' "${producer_rc}" >&2
  exit 1
}
grep -Eq 'TopicAuthorizationException|not authorized|Not authorized' "${work_dir}/denied-consumer.log" || {
  printf 'FAIL: cross-topic consumer was not explicitly denied (exit=%s)\n' "${consumer_rc}" >&2
  exit 1
}
printf 'PASS: cross-topic producer and consumer are denied by ACL\n'

head -c 3000000 /dev/urandom | base64 -w0 |
  "${bin}/kafka-console-producer.sh" --bootstrap-server "${bootstrap}" \
    --producer.config "${work_dir}/vvg-producer.properties" --topic "${vvg_topic}" \
    >"${work_dir}/valid-boundary.log" 2>&1
if grep -Eq 'RecordTooLargeException|MessageSizeTooLarge|larger than' "${work_dir}/valid-boundary.log"; then
  printf 'FAIL: 4,000,000-byte boundary record was rejected\n' >&2
  exit 1
fi
printf 'PASS: 4,000,000-byte boundary record is accepted\n'

set +e
head -c 3225000 /dev/urandom | base64 -w0 |
  "${bin}/kafka-console-producer.sh" --bootstrap-server "${bootstrap}" \
    --producer.config "${work_dir}/vvg-producer.properties" --topic "${vvg_topic}" \
    >"${work_dir}/oversized.log" 2>&1
oversized_rc=$?
set -e
grep -Eq 'RecordTooLargeException|MessageSizeTooLarge|larger than' "${work_dir}/oversized.log" || {
  printf 'FAIL: 4,300,000-byte record was not explicitly rejected (exit=%s)\n' "${oversized_rc}" >&2
  exit 1
}
printf 'PASS: 4,300,000-byte oversized record is rejected\n'

printf 'Kafka preflight passed\n'
