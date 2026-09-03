#!/usr/bin/env bash
set -euo pipefail

automq_dir="${AUTOMQ_DIR:-/data/automq}"
state_dir="${automq_dir}/runtime/watchdog"
mkdir -p "${state_dir}"
chmod 0700 "${state_dir}"
exec 9>"${state_dir}/lock"
flock -n 9 || exit 0

cd "${automq_dir}"
set -a
# shellcheck disable=SC1091
. ./.env
set +a

[[ "$(docker inspect -f '{{.State.Health.Status}}' automq 2>/dev/null || true)" == healthy ]] || exit 0

check_group() {
  local service="$1"
  local group="$2"
  local counter_file="${state_dir}/${service}.failures"
  local ids active failures id
  local -a restart_pids=()
  ids="$(docker ps --filter label=com.docker.compose.project=automq \
    --filter "label=com.docker.compose.service=${service}" --format '{{.ID}}')"
  if [[ -z "${ids}" ]]; then
    rm -f "${counter_file}"
    return
  fi
  active="$(docker exec automq /opt/automq/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server automq:19092 --command-config /etc/automq/admin-client.properties \
    --describe --group "${group}" 2>/dev/null |
    awk 'NR > 2 && $7 != "-" {seen[$7] = 1} END {for (id in seen) count++; print count + 0}')"
  if [[ "${active}" -gt 0 ]]; then
    printf '0\n' > "${counter_file}"
    return
  fi
  failures="$(cat "${counter_file}" 2>/dev/null || printf '0')"
  failures=$((failures + 1))
  printf '%s\n' "${failures}" > "${counter_file}"
  if [[ "${failures}" -ge 2 ]]; then
    printf 'Restarting %s: Kafka group %s has no active member\n' "${service}" "${group}"
    while IFS= read -r id; do
      [[ -n "${id}" ]] || continue
      docker restart -t 120 "${id}" >/dev/null &
      restart_pids+=("$!")
    done <<<"${ids}"
    for id in "${restart_pids[@]}"; do
      wait "${id}"
    done
    printf '0\n' > "${counter_file}"
  fi
}

if docker ps --filter label=com.docker.compose.service=vector-gateway-production -q | grep -q .; then
  check_group vector-gateway-production gateway-clickhouse-production-v1
else
  check_group vector-gateway-shadow "${GATEWAY_CONSUMER_GROUP}"
fi
if docker ps --filter label=com.docker.compose.service=vector-vvg-production -q | grep -q .; then
  check_group vector-vvg-production vvg-victorialogs-production-v1
else
  check_group vector-vvg-shadow "${VVG_CONSUMER_GROUP}"
fi
