#!/usr/bin/env bash
set -euo pipefail

project=${1:?project ID is required}
environment=${2:?environment is required}
partitions=${3:?partition count is required}
[[ "$project" =~ ^[a-z][a-z0-9-]{1,62}$ ]]
[[ "$environment" =~ ^(prod|stage|test|dev)$ ]]
[[ "$partitions" =~ ^[1-9][0-9]?$ ]]
cd "${AUTOMQ_DEPLOY_DIR:-/data/automq}"
test "$(docker inspect automq --format '{{index .Config.Labels "com.docker.compose.project"}}')" = automq
umask 077
for role in producer consumer; do
  file="secrets/logs-${environment}-${project}-${role}-password"
  test -s "$file" || openssl rand -hex 32 > "$file"
  chmod 600 "$file"
done
docker exec -i -e PROJECT="$project" -e ENVIRONMENT="$environment" -e PARTITIONS="$partitions" \
  -e KAFKA_HEAP_OPTS='-Xms32m -Xmx192m' -e KAFKA_JVM_PERFORMANCE_OPTS='-server -XX:+UseSerialGC' \
  automq bash -s <<'KAFKA'
set -euo pipefail
bin=/opt/automq/kafka/bin
args=(--bootstrap-server automq:19092 --command-config /etc/automq/admin-client.properties)
topic="logs.${ENVIRONMENT}.${PROJECT}.v1"
group="vmlogs.${ENVIRONMENT}.${PROJECT}.v1"
prefix="logs-${ENVIRONMENT}-${PROJECT}"
for role in producer consumer; do
  password=$(tr -d '\r\n' < "/run/secrets/${prefix}-${role}-password")
  "$bin/kafka-configs.sh" "${args[@]}" --alter --entity-type users --entity-name "${prefix}-${role}" \
    --add-config "SCRAM-SHA-512=[iterations=8192,password=${password}]" >/dev/null
done
"$bin/kafka-topics.sh" "${args[@]}" --create --if-not-exists --topic "$topic" --partitions "$PARTITIONS" \
  --replication-factor 1 --config cleanup.policy=delete --config retention.ms=259200000 \
  --config min.insync.replicas=1 --config max.message.bytes=4194304 --config compression.type=producer >/dev/null
"$bin/kafka-acls.sh" "${args[@]}" --add --allow-principal "User:${prefix}-producer" --topic "$topic" --operation Write --operation Describe >/dev/null
"$bin/kafka-acls.sh" "${args[@]}" --add --allow-principal "User:${prefix}-producer" --cluster --operation IdempotentWrite >/dev/null
"$bin/kafka-acls.sh" "${args[@]}" --add --allow-principal "User:${prefix}-consumer" --topic "$topic" --operation Read --operation Describe >/dev/null
"$bin/kafka-acls.sh" "${args[@]}" --add --allow-principal "User:${prefix}-consumer" --group "$group" --operation Read >/dev/null
"$bin/kafka-topics.sh" "${args[@]}" --describe --topic "$topic"
KAFKA
