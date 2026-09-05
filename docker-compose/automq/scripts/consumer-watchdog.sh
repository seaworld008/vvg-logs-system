#!/usr/bin/env bash
set -euo pipefail

automq_dir="${AUTOMQ_DIR:-/data/automq}"
state_dir="${automq_dir}/runtime/watchdog"
mkdir -p "${state_dir}"
chmod 0700 "${state_dir}"
exec 9>"${state_dir}/lock"
flock -n 9 || exit 0

cd "${automq_dir}"

# Read only the two group names. Compose dotenv files are not shell programs.
read_group() {
  local key="$1" value
  value="$(sed -n "s/^${key}=//p" .env | tail -n 1)"
  value="${value%$'\r'}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  [[ "${value}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'Missing or invalid %s in .env\n' "${key}" >&2
    return 1
  }
  printf '%s' "${value}"
}

if [[ "$(timeout 10 docker inspect -f '{{.State.Health.Status}}' automq 2>/dev/null || true)" != healthy ]]; then
  # An unknown/down broker interrupts consecutive confirmed-empty observations.
  rm -f -- "${state_dir}"/*.failures
  exit 0
fi

service_ids() {
  timeout 10 docker ps --filter label=com.docker.compose.project=automq \
    --filter "label=com.docker.compose.service=$1" --format '{{.ID}}'
}

check_group() {
  local service="$1"
  local group="$2"
  local counter_file="${state_dir}/${service}.failures"
  local ids="$3" description active failures id
  local -a restart_pids=()
  if [[ -z "${ids}" ]]; then
    rm -f "${counter_file}"
    return
  fi
  if ! description="$(timeout 20 docker exec automq timeout 15 \
      /opt/automq/kafka/bin/kafka-consumer-groups.sh \
      --bootstrap-server automq:19092 --command-config /etc/automq/admin-client.properties \
      --describe --state --group "${group}" 2>/dev/null)"; then
    rm -f "${counter_file}"
    printf 'Skipping %s: Kafka group state query failed\n' "${service}" >&2
    return
  fi
  # --state describes membership even when a group has not committed offsets.
  # Unknown/rebalancing output must never be interpreted as an empty group.
  active="$(awk -v group="${group}" '
    $1 == group && NF >= 4 && $NF ~ /^[0-9]+$/ {
      if ($NF > 0) print $NF
      else if ($(NF-1) == "Empty") print 0
    }
  ' <<<"${description}")"
  if [[ ! "${active}" =~ ^[0-9]+$ ]]; then
    rm -f "${counter_file}"
    printf 'Skipping %s: Kafka group membership is unknown\n' "${service}" >&2
    return
  fi
  if [[ "${active}" -gt 0 ]]; then
    printf '0\n' > "${counter_file}"
    return
  fi
  failures="$(cat "${counter_file}" 2>/dev/null || printf '0')"
  [[ "${failures}" =~ ^[01]$ ]] || failures=0
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
      if ! wait "${id}"; then
        printf 'Consumer restart failed for %s\n' "${service}" >&2
      fi
    done
    printf '0\n' > "${counter_file}"
  fi
}

check_pipeline() {
  local production="$1" group="$2" shadow="$3" shadow_key="$4" ids shadow_group
  if ! ids="$(service_ids "${production}")"; then
    rm -f "${state_dir}/${production}.failures" "${state_dir}/${shadow}.failures"
    return
  fi
  if [[ -n "${ids}" ]]; then
    rm -f "${state_dir}/${shadow}.failures"
    check_group "${production}" "${group}" "${ids}"
  else
    rm -f "${state_dir}/${production}.failures"
    if ! ids="$(service_ids "${shadow}")"; then
      rm -f "${state_dir}/${shadow}.failures"
      return
    fi
    if [[ -z "${ids}" ]]; then
      rm -f "${state_dir}/${shadow}.failures"
      return
    fi
    if ! shadow_group="$(read_group "${shadow_key}")"; then
      rm -f "${state_dir}/${shadow}.failures"
      return
    fi
    check_group "${shadow}" "${shadow_group}" "${ids}"
  fi
}

check_pipeline vector-gateway-production gateway-clickhouse-production-v1 \
  vector-gateway-shadow GATEWAY_CONSUMER_GROUP
check_pipeline vector-vvg-production vvg-victorialogs-production-v1 \
  vector-vvg-shadow VVG_CONSUMER_GROUP
