#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root_dir}"

read_env() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" .env | tail -n 1)"
  value="${value%$'\r'}"
  [[ -n "${value}" ]] || {
    printf 'Missing %s in %s/.env\n' "${key}" "${root_dir}" >&2
    exit 1
  }
  printf '%s' "${value}"
}

require_safe_value() {
  local name="$1"
  local value="$2"
  local pattern="$3"
  [[ "${value}" =~ ${pattern} ]] || {
    printf 'Unsafe or invalid %s value\n' "${name}" >&2
    exit 1
  }
}

install -d -m 0700 runtime secrets state/kraft state/logs \
  state/vector-vvg-shadow state/vector-gateway-shadow \
  state/vector-vvg-production state/vector-gateway-production state/vmagent \
  secrets/vvg-producer secrets/gateway-producer \
  secrets/vvg-consumer secrets/gateway-consumer secrets/clickhouse
chmod 0600 .env

for secret_name in automq-admin-password vvg-producer-password \
  gateway-producer-password vvg-consumer-password gateway-consumer-password; do
  secret_path="secrets/${secret_name}"
  if [[ ! -s "${secret_path}" ]]; then
    umask 077
    openssl rand -hex 32 > "${secret_path}"
  fi
  chmod 0600 "${secret_path}"
done

for required_secret in obs-access-key obs-secret-key; do
  [[ -s "secrets/${required_secret}" ]] || {
    printf 'Create secrets/%s before rendering runtime files\n' "${required_secret}" >&2
    exit 1
  }
  chmod 0600 "secrets/${required_secret}"
done

admin_password="$(tr -d '\r\n' < secrets/automq-admin-password)"
require_safe_value AUTOMQ_ADMIN_PASSWORD "${admin_password}" '^[0-9a-f]{64}$'

host_ip="$(read_env AUTOMQ_HOST_IP)"
external_port="$(read_env AUTOMQ_EXTERNAL_PORT)"
bucket="$(read_env AUTOMQ_OBS_BUCKET)"
region="$(read_env AUTOMQ_OBS_REGION)"
endpoint="$(read_env AUTOMQ_OBS_ENDPOINT)"
cce_node_1="$(read_env CCE_NODE_1)"
cce_node_2="$(read_env CCE_NODE_2)"
victorialogs_metrics_target="$(read_env VICTORIALOGS_METRICS_TARGET)"

require_safe_value AUTOMQ_HOST_IP "${host_ip}" '^[0-9A-Fa-f:.]+$'
require_safe_value AUTOMQ_EXTERNAL_PORT "${external_port}" '^[0-9]{2,5}$'
require_safe_value AUTOMQ_OBS_BUCKET "${bucket}" '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'
require_safe_value AUTOMQ_OBS_REGION "${region}" '^[a-z0-9-]+$'
require_safe_value AUTOMQ_OBS_ENDPOINT "${endpoint}" '^https://[A-Za-z0-9.-]+(:[0-9]+)?$'
require_safe_value CCE_NODE_1 "${cce_node_1}" '^[0-9A-Fa-f:.]+$'
require_safe_value CCE_NODE_2 "${cce_node_2}" '^[0-9A-Fa-f:.]+$'
require_safe_value VICTORIALOGS_METRICS_TARGET "${victorialogs_metrics_target}" \
  '^[A-Za-z0-9.-]+:[0-9]{2,5}$'

sed \
  -e "s/__AUTOMQ_HOST_IP__/${host_ip}/g" \
  -e "s/__AUTOMQ_EXTERNAL_PORT__/${external_port}/g" \
  -e "s/__AUTOMQ_OBS_BUCKET__/${bucket}/g" \
  -e "s/__AUTOMQ_OBS_REGION__/${region}/g" \
  -e "s#__AUTOMQ_OBS_ENDPOINT__#${endpoint}#g" \
  -e "s/__AUTOMQ_ADMIN_PASSWORD__/${admin_password}/g" \
  config/server.properties.template > runtime/server.properties
chmod 0600 runtime/server.properties

cat > runtime/admin-client.properties <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="automq-admin" password="${admin_password}";
EOF
chmod 0600 runtime/admin-client.properties

for identity in vvg-producer gateway-producer vvg-consumer gateway-consumer; do
  install -d -m 0700 "secrets/${identity}"
  tr -d '\r\n' < "secrets/${identity}-password" > "secrets/${identity}/password"
  chmod 0600 "secrets/${identity}/password"
done

sed \
  -e "s/__CCE_NODE_1__/${cce_node_1}/g" \
  -e "s/__CCE_NODE_2__/${cce_node_2}/g" \
  -e "s/__VICTORIALOGS_METRICS_TARGET__/${victorialogs_metrics_target}/g" \
  config/prometheus.yml.template > runtime/prometheus.yml
chmod 0644 runtime/prometheus.yml

if [[ ! -s secrets/cluster-id ]]; then
  automq_image="$(read_env AUTOMQ_IMAGE)"
  docker run --rm --entrypoint /opt/automq/kafka/bin/kafka-storage.sh \
    "${automq_image}" random-uuid > secrets/cluster-id
fi
chmod 0600 secrets/cluster-id

find secrets -type f -exec chmod 0600 {} +
printf 'Rendered AutoMQ runtime configuration without printing secrets\n'
