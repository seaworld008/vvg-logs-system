#!/usr/bin/env bash
set -euo pipefail

export KAFKA_S3_ACCESS_KEY="$(tr -d '\r\n' < /run/secrets/obs-access-key)"
export KAFKA_S3_SECRET_KEY="$(tr -d '\r\n' < /run/secrets/obs-secret-key)"

exec /opt/automq/kafka/bin/kafka-server-start.sh /etc/automq/server.properties
