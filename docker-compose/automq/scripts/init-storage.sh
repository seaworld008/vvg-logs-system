#!/usr/bin/env bash
set -euo pipefail

metadata_dir=/var/lib/automq
config=/etc/automq/server.properties
cluster_id="$(tr -d '\r\n' < /run/secrets/cluster-id)"
admin_password="$(tr -d '\r\n' < /run/secrets/automq-admin-password)"

if [[ -f "${metadata_dir}/meta.properties" ]]; then
  grep -Fqx "cluster.id=${cluster_id}" "${metadata_dir}/meta.properties"
  exit 0
fi

/opt/automq/kafka/bin/kafka-storage.sh format \
  --cluster-id "${cluster_id}" \
  --config "${config}" \
  --add-scram "SCRAM-SHA-512=[name=automq-admin,iterations=8192,password=${admin_password}]"
