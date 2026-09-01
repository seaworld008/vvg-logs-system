#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

mode="${1:---static}"
failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_literal() {
  local path="$1"
  local value="$2"
  local description="$3"

  if grep -Fq -- "${value}" "${path}"; then
    pass "${description}"
  else
    fail "${description} (${path} must contain: ${value})"
  fi
}

forbid_regex() {
  local path="$1"
  local pattern="$2"
  local description="$3"

  if grep -Eq -- "${pattern}" "${path}"; then
    fail "${description} (${path})"
  else
    pass "${description}"
  fi
}

validate_static() {
  local grafana_compose="docker-compose/grafana/docker-compose.yml"
  local grafana_env="docker-compose/grafana/env.example"
  local grafana_datasource="docker-compose/grafana/datasources/victorialogs.yaml"
  local victorialogs_compose="docker-compose/victorialogs/docker-compose.yml"
  local vector_config="docker-compose/vector/vector.yaml"
  local password_value
  local tracked_sensitive

  require_literal ".gitignore" '**/.env' \
    "Deployment .env files are ignored"
  require_literal ".gitignore" '**/服务器信息.txt' \
    "Local server credential files are ignored"
  tracked_sensitive="$(git ls-files | grep -E '(^|/)(\.env|服务器信息\.txt)$' || true)"
  if [[ -n "${tracked_sensitive}" ]]; then
    printf '%s\n' "${tracked_sensitive}" >&2
    fail "Local deployment credentials must not be tracked"
  else
    pass "No local deployment credential files are tracked"
  fi

  forbid_regex "${grafana_compose}" 'GF_(INSTALL_PLUGINS|PLUGINS_PREINSTALL)' \
    "Grafana startup has no online plugin installation"
  forbid_regex "${grafana_compose}" 'grafana-(piechart|worldmap)-panel' \
    "Grafana does not load legacy Angular panels"
  forbid_regex "${grafana_compose}" 'ALLOW_LOADING_UNSIGNED_PLUGINS' \
    "Grafana does not allow unsigned plugins"

  require_literal "${grafana_compose}" 'GF_EXPLORE_DEFAULTTIMEOFFSET=15m' \
    "Grafana Explore defaults to 15 minutes"
  require_literal "${grafana_env}" 'GRAFANA_VERSION=13.2.0-ubuntu' \
    "Grafana version is pinned"
  require_literal "${grafana_env}" 'VICTORIALOGS_PLUGIN_VERSION=0.31.0' \
    "VictoriaLogs Grafana plugin version is pinned"
  require_literal "docker-compose/grafana/Dockerfile" 'FROM grafana/grafana:${GRAFANA_VERSION}' \
    "Grafana custom image uses the pinned build argument"
  require_literal "docker-compose/grafana/Dockerfile" 'plugins install victoriametrics-logs-datasource' \
    "Grafana plugin is installed at image build time"
  require_literal "docker-compose/grafana/Dockerfile" 'ENV GF_PATHS_PLUGINS=/var/lib/grafana-plugins' \
    "Grafana image stores plugins outside the mounted data directory"
  require_literal "${grafana_compose}" 'GF_PATHS_PLUGINS=/var/lib/grafana-plugins' \
    "Grafana runtime uses the image-baked plugin directory"
  require_literal "${grafana_datasource}" 'uid: victorialogs-ds' \
    "Grafana data source has a stable UID"
  require_literal "${grafana_datasource}" 'maxLines: 2000' \
    "Grafana log result size is bounded"
  require_literal "${grafana_datasource}" 'timeout: 60' \
    "Grafana data source timeout is explicit"
  require_literal "${grafana_datasource}" 'editable: false' \
    "Provisioned Grafana data source is immutable"

  password_value="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' "${grafana_env}" | head -n 1)"
  password_value="${password_value%$'\r'}"
  if [[ "${password_value}" == "CHANGE_ME_BEFORE_DEPLOY" ]]; then
    pass "Grafana example contains only a non-secret password placeholder"
  else
    fail "Grafana example must use GRAFANA_ADMIN_PASSWORD=CHANGE_ME_BEFORE_DEPLOY"
  fi

  require_literal "${victorialogs_compose}" '--search.maxConcurrentRequests=${VL_SEARCH_MAX_CONCURRENT_REQUESTS}' \
    "VictoriaLogs query concurrency is parameterized"
  require_literal "${victorialogs_compose}" '--search.logSlowQueryDuration=${VL_SEARCH_SLOW_QUERY_DURATION}' \
    "VictoriaLogs slow-query logging is parameterized"

  require_literal "${vector_config}" 'glob_minimum_cooldown_ms: 1000' \
    "Docker Vector discovers files every second"
  require_literal "${vector_config}" 'timeout_secs: 1' \
    "Docker Vector bounds batch latency to one second"
  require_literal "${vector_config}" 'when_full: block' \
    "Docker Vector applies lossless buffer backpressure"
  forbid_regex "${vector_config}" '^  console:' \
    "Docker Vector does not duplicate business logs to stdout"
  require_literal "docker-compose/vector/env.example" 'VECTOR_API_BIND=127.0.0.1' \
    "Docker Vector API binds to host loopback by default"

  if grep -R -n -E --include='*.yaml' --include='*.yml' \
      'drop_newest|rewrite_timestamp' docker-compose k8s-deployment >/dev/null; then
    fail "Active YAML must not drop newest logs or rewrite event timestamps"
  else
    pass "Active YAML preserves logs and event timestamps"
  fi

  if grep -n -E '(^|[=:])[^#[:space:]]*latest([[:space:]]|$)' \
      docker-compose/*/env.example docker-compose/*/docker-compose.yml >/dev/null; then
    fail "Compose baselines must not use latest tags"
  else
    pass "Compose baselines use pinned versions"
  fi

  if grep -n '^version:' docker-compose/*/docker-compose.yml >/dev/null; then
    fail "Compose files must not use the obsolete top-level version field"
  else
    pass "Compose files omit the obsolete top-level version field"
  fi
}

extract_vector_config() {
  local manifest="$1"
  local output="$2"

  awk '
    { sub(/\r$/, "") }
    found && /^---$/ { exit }
    found { sub(/^    /, ""); print }
    $0 == "  vector.yaml: |" { found=1 }
  ' "${manifest}" > "${output}"

  if [[ ! -s "${output}" ]]; then
    printf 'Unable to extract vector.yaml from %s\n' "${manifest}" >&2
    return 1
  fi
}

validate_vector_file() {
  local config_path="$1"

  docker run --rm \
    -e VLS_ENDPOINT=http://victorialogs.example:9428 \
    -e HOSTNAME=validation-node \
    -e VECTOR_SELF_NODE_NAME=validation-node \
    -e VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true \
    -v "${config_path}:/etc/vector/vector.yaml:ro" \
    timberio/vector:0.58.0-alpine \
    validate --no-environment /etc/vector/vector.yaml
}

validate_runtime() {
  local temp_dir
  local manifest
  local extracted
  local grafana_version
  local plugin_version
  local plugin_list

  command -v docker >/dev/null 2>&1 || {
    printf 'docker is required for --runtime validation\n' >&2
    return 1
  }
  docker compose version

  for component in grafana victorialogs vector; do
    docker compose \
      --env-file "docker-compose/${component}/env.example" \
      -f "docker-compose/${component}/docker-compose.yml" \
      config --quiet
    pass "${component} Compose configuration expands"
  done

  if [[ "${VVG_SKIP_GRAFANA_BUILD:-0}" == "1" ]]; then
    printf 'SKIP: Grafana image build explicitly disabled by VVG_SKIP_GRAFANA_BUILD=1\n'
  else
    grafana_version="$(sed -n 's/^GRAFANA_VERSION=//p' docker-compose/grafana/env.example)"
    plugin_version="$(sed -n 's/^VICTORIALOGS_PLUGIN_VERSION=//p' docker-compose/grafana/env.example)"
    grafana_version="${grafana_version%$'\r'}"
    plugin_version="${plugin_version%$'\r'}"
    docker build \
      --build-arg "GRAFANA_VERSION=${grafana_version}" \
      --build-arg "VICTORIALOGS_PLUGIN_VERSION=${plugin_version}" \
      -t vvg-grafana:config-validation \
      docker-compose/grafana
    temp_dir="$(mktemp -d)"
    trap "rm -rf -- '${temp_dir}'" EXIT
    chmod 0777 "${temp_dir}"
    plugin_list="$(docker run --rm \
      -v "${temp_dir}:/var/lib/grafana" \
      --entrypoint grafana \
      vvg-grafana:config-validation \
      cli --pluginsDir /var/lib/grafana-plugins plugins ls)"
    rm -rf "${temp_dir}"
    trap - EXIT
    if grep -Fq "victoriametrics-logs-datasource @ ${plugin_version}" <<<"${plugin_list}"; then
      pass "Grafana image exposes VictoriaLogs plugin ${plugin_version} with a mounted data directory"
    else
      printf '%s\n' "${plugin_list}" >&2
      printf 'Grafana image does not contain the expected VictoriaLogs plugin version\n' >&2
      return 1
    fi
  fi

  validate_vector_file "${repo_root}/docker-compose/vector/vector.yaml"
  pass "Docker Vector configuration validates"

  temp_dir="$(mktemp -d)"
  trap "rm -rf -- '${temp_dir}'" EXIT
  for manifest in k8s-deployment/vector-k8s-containerd-cri.yaml \
                  k8s-deployment/vector-k8s-docker-cri.yaml; do
    extracted="${temp_dir}/$(basename "${manifest}").vector.yaml"
    extract_vector_config "${manifest}" "${extracted}"
    validate_vector_file "${extracted}"
    pass "${manifest} embedded Vector configuration validates"
  done
  rm -rf "${temp_dir}"
  trap - EXIT
}

case "${mode}" in
  --static)
    validate_static
    if (( failures > 0 )); then
      printf '%d static validation check(s) failed\n' "${failures}" >&2
      exit 1
    fi
    ;;
  --runtime)
    validate_static
    if (( failures > 0 )); then
      printf '%d static validation check(s) failed; runtime checks skipped\n' "${failures}" >&2
      exit 1
    fi
    validate_runtime
    ;;
  *)
    printf 'Usage: %s [--static|--runtime]\n' "$0" >&2
    exit 2
    ;;
esac

printf 'VVG configuration validation passed (%s)\n' "${mode}"
