#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

mode="${1:---static}"
compose="docker-compose/clickhouse/docker-compose.yml"
retention="docker-compose/clickhouse/config/observability.xml"
schema="docker-compose/clickhouse/initdb/001-gateway-schema.sql"
vector_manifest="k8s-deployment/vector/gateway/direct-containerd.yaml"
automq_manifest="k8s-deployment/vector/gateway/automq-containerd-production.yaml"
geoip_notice="k8s-deployment/vector/gateway/geoip/NOTICE.md"
datasource="docker-compose/grafana/routes/gateway-clickhouse/datasources/clickhouse.yaml"
dashboard="docker-compose/grafana/routes/gateway-clickhouse/dashboards/gateway-observability.json"
grafana_override="docker-compose/grafana/routes/gateway-clickhouse/compose.override.example.yml"
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

require_file() {
  if [[ -s "$1" ]]; then pass "$2"; else fail "$2 ($1 missing or empty)"; fi
}

require_literal() {
  if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3 ($1 must contain: $2)"; fi
}

forbid_regex() {
  if grep -Eq -- "$2" "$1"; then fail "$3 ($1)"; else pass "$3"; fi
}

validate_static() {
  for path in \
    "docker-compose/clickhouse/README.md" \
    "k8s-deployment/vector/gateway/README.md" \
    "docker-compose/grafana/routes/gateway-clickhouse/README.md" \
    "docs/log-pipeline-selection.md" \
    "docs/vector-clickhouse-gateway-runbook.md" \
    "docs/decisions/0001-vector-clickhouse-gateway.md" \
    "docs/decisions/0003-service-oriented-log-deployment-layout.md" \
    "docs/images/clickhouse-gateway-overview.png" \
    "${compose}" "${retention}" "${schema}" "${vector_manifest}" \
    "${automq_manifest}" "${geoip_notice}" "${datasource}" "${dashboard}" \
    "${grafana_override}"; do
    require_file "${path}" "${path} exists"
  done

  require_literal ".gitignore" 'docker-compose/clickhouse/data/' \
    "ClickHouse runtime data is ignored in its service directory"
  require_literal ".gitignore" 'k8s-deployment/vector/gateway/geoip/*.mmdb' \
    "Gateway GeoIP runtime data is ignored"

  require_literal "${compose}" 'clickhouse-server:26.8.2.7-alpine' \
    "ClickHouse image uses the validated LTS patch"
  require_literal "${compose}" 'pull_policy: never' \
    "ClickHouse startup cannot pull online"
  require_literal "${compose}" 'CHANGE_ME_BEFORE_DEPLOY' \
    "ClickHouse template contains only a password placeholder"
  require_literal "${compose}" 'stop_grace_period: 2m' \
    "ClickHouse has a graceful stop window"
  require_literal "${compose}" 'mem_limit: 8g' \
    "ClickHouse memory is bounded"
  require_literal "${compose}" 'pids_limit: 4096' \
    "ClickHouse process count is bounded"
  require_literal "${compose}" '/etc/clickhouse-server/config.d:ro' \
    "ClickHouse configuration is read-only"
  require_literal "${compose}" 'clickhouse-client --user' \
    "ClickHouse has an authenticated health check"
  forbid_regex "${compose}" '(^|[/:])latest([[:space:]@]|$)' \
    "ClickHouse image is not latest"

  require_literal "${retention}" '<query_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_log>' \
    "ClickHouse query log retention is bounded"
  require_literal "${retention}" '<trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>' \
    "ClickHouse trace log retention is bounded"
  require_literal "${retention}" '<part_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></part_log>' \
    "ClickHouse part log retention is bounded"

  require_literal "${schema}" 'PARTITION BY toYYYYMM(timestamp)' \
    "Gateway table uses monthly partitions"
  require_literal "${schema}" 'PRIMARY KEY (timestamp, domain, status, top_path)' \
    "Gateway table uses a compact primary key"
  require_literal "${schema}" 'TTL toDateTime(timestamp) + INTERVAL 30 DAY DELETE' \
    "Gateway business retention is explicit"
  forbid_regex "${schema}" 'PRIMARY KEY \([^)]*,[^)]*,[^)]*,[^)]*,[^)]*,' \
    "Gateway primary key is not excessively wide"

  require_literal "${vector_manifest}" 'image: registry.example.com/observability/timberio/vector:0.58.0-alpine' \
    "Gateway Vector image is pinned"
  require_literal "${vector_manifest}" 'ignore_checkpoints: false' \
    "Gateway Vector resumes checkpoints"
  require_literal "${vector_manifest}" 'max_line_bytes: 16777216' \
    "Gateway Vector accepts raw lines up to 16 MiB before multiline parsing"
  require_literal "${vector_manifest}" 'path: /var/lib/vector-clickhouse-gateway' \
    "Gateway Vector state is persistent and isolated"
  require_literal "${vector_manifest}" 'type: directory' \
    "Gateway Vector uses a secret backend"
  require_literal "${vector_manifest}" 'password: SECRET[clickhouse_auth.password]' \
    "Gateway Vector password is not stored in ConfigMap"
  require_literal "${vector_manifest}" 'compression: gzip' \
    "Gateway Vector compresses ClickHouse requests"
  require_literal "${vector_manifest}" 'max_size: 1073741824' \
    "Gateway Vector has a 1 GiB disk buffer"
  require_literal "${vector_manifest}" 'when_full: block' \
    "Gateway Vector applies lossless backpressure"
  require_literal "${vector_manifest}" 'timeout_secs: 180' \
    "Vector timeout exceeds ClickHouse async wait"
  require_literal "${vector_manifest}" '"timestamp": format_timestamp!(event_time, "%+")' \
    "Gateway Vector serializes event time explicitly"
  require_literal "${vector_manifest}" '"createdtime": format_timestamp!(now(), "%+")' \
    "Gateway Vector serializes ingest time explicitly"
  require_literal "${vector_manifest}" 'type: mmdb' \
    "Gateway Vector uses the DB-IP-compatible MMDB table"
  require_literal "${vector_manifest}" 'dbip-city-lite-2026-09.mmdb' \
    "Gateway Vector pins the GeoIP database release"
  require_literal "${vector_manifest}" '05a10861259c7966cb54d7181ef8c360de8c8829d182098c0e62a9b7d54cd50d' \
    "Gateway Vector pins the GeoIP database checksum"
  require_literal "${vector_manifest}" 'releases/download/geoip-dbip-city-lite-2026-09/' \
    "Gateway Vector downloads GeoIP from a fixed GitHub Release"
  require_literal "${vector_manifest}" 'get_enrichment_table_record("geoip_table"' \
    "Gateway Vector enriches client location"
  require_literal "${geoip_notice}" 'Creative Commons Attribution 4.0 International' \
    "GeoIP redistribution license is documented"
  require_literal "${geoip_notice}" 'IP Geolocation by DB-IP' \
    "GeoIP attribution is documented"
  require_literal "${vector_manifest}" 'enabled: true' \
    "Gateway Vector enables acknowledgements and async insert"
  forbid_regex "${vector_manifest}" 'retry_attempts|drop_newest|ignore_checkpoints: true' \
    "Gateway Vector has no finite retry or lossy checkpoint policy"
  forbid_regex "${vector_manifest}" 'to_unix_timestamp' \
    "Gateway Vector does not rely on numeric DateTime64 inference"
  forbid_regex "${vector_manifest}" 'access_vector_error|/tmp/.*error.*\.log' \
    "Gateway parse failures cannot create an unbounded raw file"
  require_literal "${automq_manifest}" 'compression: zstd' \
    "Gateway AutoMQ producer uses Zstd"
  require_literal "${automq_manifest}" 'secretName: automq-gateway-producer' \
    "Gateway AutoMQ producer uses an independent Secret"
  require_literal "${automq_manifest}" '- route_automq_gateway_size.normal' \
    "Gateway AutoMQ sink receives only parsed size-routed events"

  require_literal "${datasource}" 'uid: gateway-clickhouse' \
    "Grafana ClickHouse datasource UID is stable"
  require_literal "${datasource}" 'version: 4.5.1' \
    "Grafana ClickHouse datasource plugin contract is pinned"
  require_literal "${datasource}" 'password: $CLICKHOUSE_GRAFANA_PASSWORD' \
    "Grafana datasource password comes from a secret environment variable"
  forbid_regex "${datasource}" 'password:[[:space:]]+[^$]' \
    "Grafana datasource contains no plaintext password"
  require_literal "${grafana_override}" \
    'CLICKHOUSE_GRAFANA_PASSWORD=${CLICKHOUSE_GRAFANA_PASSWORD}' \
    "Grafana Gateway route injects the read-only datasource password"
  if [[ "$(grep -Fc ':ro' "${grafana_override}")" == 3 ]]; then
    pass "Grafana Gateway route mounts all provisioning inputs read-only"
  else
    fail "Grafana Gateway route must mount all provisioning inputs read-only"
  fi
  require_literal "README.md" 'docs/images/clickhouse-gateway-overview.png' \
    "README displays the sanitized Gateway Dashboard"

  local node_command=""
  if command -v node >/dev/null 2>&1; then
    node_command="node"
  elif command -v node.exe >/dev/null 2>&1; then
    node_command="node.exe"
  fi
  if [[ -n "${node_command}" ]] \
      && "${node_command}" scripts/validate-clickhouse-gateway.mjs; then
    pass "Gateway ClickHouse Dashboard validates"
  else
    fail "Gateway ClickHouse Dashboard validates"
  fi

  if grep -R -n -E '(192\.168\.|172\.18\.|([a-z0-9-]+\.)+cn([^a-z0-9-]|$)|myhuaweicloud\.com|\.obs\.)' \
      docker-compose/clickhouse k8s-deployment/vector/gateway \
      docker-compose/grafana/routes/gateway-clickhouse \
      docs/vector-clickhouse-gateway-runbook.md \
      docs/decisions/0001-vector-clickhouse-gateway.md >/dev/null; then
    fail "Gateway ClickHouse deliverables contain no production addresses"
  else
    pass "Gateway ClickHouse deliverables contain no production addresses"
  fi
  if [[ -e clickhouse-gateway ]]; then
    fail "Legacy clickhouse-gateway directory must not exist"
  else
    pass "Gateway assets use the service-oriented repository layout"
  fi
}

extract_vector_config() {
  awk '
    { sub(/\r$/, "") }
    found && /^---$/ { exit }
    found { sub(/^    /, ""); print }
    $0 == "  vector.yaml: |" { found=1 }
  ' "${vector_manifest}" > "$1"
  [[ -s "$1" ]]
}

validate_runtime() {
  command -v docker >/dev/null 2>&1 || {
    printf 'docker is required for --runtime\n' >&2
    return 1
  }

  docker compose -f "${compose}" config --quiet
  pass "Gateway ClickHouse Compose expands"
  CLICKHOUSE_GRAFANA_PASSWORD=validation-password \
    docker compose --env-file docker-compose/grafana/env.example \
      -f docker-compose/grafana/docker-compose.yml \
      -f "${grafana_override}" config --quiet
  pass "Grafana Compose expands with the optional Gateway ClickHouse route"

  local temp_dir vector_config geoip_path expected_geoip
  temp_dir="$(mktemp -d)"
  trap "rm -rf -- '${temp_dir}'" EXIT
  vector_config="${temp_dir}/vector.yaml"
  expected_geoip="05a10861259c7966cb54d7181ef8c360de8c8829d182098c0e62a9b7d54cd50d"
  geoip_path="${GATEWAY_GEOIP_MMDB:-${temp_dir}/dbip-city-lite-2026-09.mmdb}"
  if [[ ! -f "${geoip_path}" ]]; then
    command -v curl >/dev/null 2>&1 || {
      printf 'curl is required to download the pinned GeoIP validation asset\n' >&2
      return 1
    }
    curl -L --fail --retry 5 --retry-all-errors --connect-timeout 30 --max-time 900 \
      -o "${geoip_path}" \
      https://github.com/seaworld008/vvg-logs-system/releases/download/geoip-dbip-city-lite-2026-09/dbip-city-lite-2026-09.mmdb
  fi
  echo "${expected_geoip}  ${geoip_path}" | sha256sum -c -
  pass "Gateway GeoIP release asset checksum validates"
  extract_vector_config "${vector_config}"
  mkdir -p "${temp_dir}/secrets"
  printf 'validation-user' > "${temp_dir}/secrets/username"
  printf 'validation-password' > "${temp_dir}/secrets/password"
  docker run --rm \
    -v "${vector_config}:/etc/vector/vector.yaml:ro" \
    -v "${temp_dir}/secrets:/var/run/secrets/clickhouse:ro" \
    -v "${geoip_path}:/var/lib/vector/geoip/dbip-city-lite-2026-09.mmdb:ro" \
    timberio/vector:0.58.0-alpine \
    validate --no-environment /etc/vector/vector.yaml
  pass "Gateway Vector configuration compiles on 0.58.0"
  rm -rf "${temp_dir}"
  trap - EXIT
}

case "${mode}" in
  --static) validate_static ;;
  --runtime) validate_static; validate_runtime ;;
  *) printf 'Usage: %s [--static|--runtime]\n' "$0" >&2; exit 2 ;;
esac

if (( failures > 0 )); then
  printf '%d Gateway ClickHouse validation check(s) failed\n' "${failures}" >&2
  exit 1
fi

printf 'Gateway ClickHouse validation passed (%s)\n' "${mode}"
