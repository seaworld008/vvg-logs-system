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

validate_json_file() {
  local path="$1"
  local description="$2"

  if command -v python3 >/dev/null 2>&1 \
      && python3 -m json.tool "${path}" >/dev/null 2>&1; then
    pass "${description}"
  elif command -v python >/dev/null 2>&1 \
      && python -m json.tool "${path}" >/dev/null 2>&1; then
    pass "${description}"
  elif command -v node >/dev/null 2>&1 \
      && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' \
        "${path}" >/dev/null 2>&1; then
    pass "${description}"
  else
    fail "${description} (${path} is invalid or no JSON parser is available)"
  fi
}

require_file() {
  local path="$1"
  local description="$2"

  if [[ -f "${path}" && -s "${path}" ]]; then
    pass "${description}"
  else
    fail "${description} (${path} is missing or empty)"
  fi
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
  local grafana_dashboard="docker-compose/grafana/dashboards/vvg-log-search.json"
  local mcp_compose="docker-compose/mcp-victorialogs/docker-compose.yml"
  local mcp_env="docker-compose/mcp-victorialogs/env.example"
  local mcp_auth="docker-compose/mcp-victorialogs/vmauth/auth.example.yml"
  local victorialogs_compose="docker-compose/victorialogs/docker-compose.yml"
  local vector_config="docker-compose/vector/vector.yaml"
  local password_value
  local tracked_sensitive
  local node_command=""

  require_literal ".gitignore" '**/.env' \
    "Deployment .env files are ignored"
  require_literal ".gitignore" '**/服务器信息.txt' \
    "Local server credential files are ignored"
  require_file "AGENTS.md" "Repository AI agent instructions exist"
  require_file "docs/ai-agent-operations-guide.md" "AI agent operations guide exists"
  require_file "docs/vector-clickhouse-gateway-runbook.md" \
    "Vector ClickHouse Gateway runbook exists"
  require_file "docs/images/vvg-dashboard-overview.png" "Sanitized dashboard overview exists"
  require_file "docs/images/vvg-message-filter-builder.png" "Sanitized message filter screenshot exists"
  require_file "docker-compose/mcp-victorialogs/README.md" \
    "VictoriaLogs MCP deployment guide exists"
  require_literal "README.md" 'docs/images/vvg-dashboard-overview.png' \
    "README displays the dashboard overview"
  require_literal "README.md" 'docs/images/vvg-message-filter-builder.png' \
    "README displays the message filter builder"
  require_literal "README.md" 'docs/ai-agent-operations-guide.md' \
    "README links the AI agent operations guide"
  require_literal "README.md" 'docs/grafana-victorialogs-研发现场日志查询%20&%20过滤手册.md' \
    "README links the developer query quick reference"
  local readme_core_line
  local readme_docs_line
  local readme_gateway_line
  readme_core_line="$(grep -nF '## VVG 核心架构' README.md | head -n 1 | cut -d: -f1)"
  readme_docs_line="$(grep -nF '## VVG 主系统文档' README.md | head -n 1 | cut -d: -f1)"
  readme_gateway_line="$(grep -nF '## 附加方案：Gateway 结构化日志分析' README.md | head -n 1 | cut -d: -f1)"
  if [[ -n "${readme_core_line}" && -n "${readme_docs_line}" \
      && -n "${readme_gateway_line}" \
      && "${readme_core_line}" -lt "${readme_gateway_line}" \
      && "${readme_docs_line}" -lt "${readme_gateway_line}" ]]; then
    pass "README prioritizes the VVG log system before the Gateway add-on"
  else
    fail "README must place VVG architecture and documentation before the Gateway add-on"
  fi
  require_literal "README.md" 'docker-compose/mcp-victorialogs/README.md' \
    "README links the VictoriaLogs MCP deployment guide"
  tracked_sensitive="$(git ls-files | grep -E '(^|/)(\.env|服务器信息\.txt)$' || true)"
  if [[ -n "${tracked_sensitive}" ]]; then
    printf '%s\n' "${tracked_sensitive}" >&2
    fail "Local deployment credentials must not be tracked"
  else
    pass "No local deployment credential files are tracked"
  fi

  forbid_regex "${grafana_compose}" 'GF_(INSTALL_PLUGINS|PLUGINS_PREINSTALL=|PLUGINS_PREINSTALL_SYNC=)' \
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
  require_literal "${grafana_env}" 'BUSINESS_TEXT_PLUGIN_VERSION=6.3.0' \
    "Business Text plugin version is pinned"
  require_literal "${grafana_env}" 'GRAFANA_IMAGE=grafana/grafana:13.2.0-ubuntu' \
    "Grafana uses a pinned official image"
  require_literal "${grafana_env}" 'GRAFANA_PLUGINS_DIR=/data/grafana/plugins/releases/grafana13.2.0-vl0.31.0-text6.3.0' \
    "Grafana external plugin bundle path is versioned"
  require_literal "${grafana_compose}" '${GRAFANA_PLUGINS_DIR}:/var/lib/grafana-plugins:ro' \
    "Grafana mounts the external plugin bundle read-only"
  require_literal "${grafana_compose}" 'GF_PLUGINS_PREINSTALL_DISABLED=true' \
    "Grafana default plugin preinstallation is disabled"
  require_literal "${grafana_compose}" 'GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false' \
    "Grafana plugin auto-update is disabled"
  require_literal "${grafana_compose}" 'GF_PATHS_PLUGINS=/var/lib/grafana-plugins' \
    "Grafana runtime scans the external plugin directory"
  require_literal "scripts/install-grafana-plugins.sh" 'plugins install victoriametrics-logs-datasource "${VICTORIALOGS_PLUGIN_VERSION}"' \
    "Plugin bundle installer pins VictoriaLogs"
  require_literal "scripts/install-grafana-plugins.sh" 'plugins install marcusolsson-dynamictext-panel "${BUSINESS_TEXT_PLUGIN_VERSION}"' \
    "Plugin bundle installer pins Business Text"
  require_literal "scripts/install-grafana-plugins.sh" 'mktemp -d' \
    "Plugin bundle installer stages changes atomically"
  require_literal "scripts/install-grafana-plugins.sh" '--user "${installer_uid}:${installer_gid}"' \
    "Plugin bundle installer preserves host ownership"
  require_literal "${grafana_compose}" 'cpus: ${GRAFANA_CPU_LIMIT}' \
    "Grafana CPU usage is bounded"
  require_literal "${grafana_compose}" 'mem_limit: ${GRAFANA_MEMORY_LIMIT}' \
    "Grafana memory usage is bounded"
  require_literal "${grafana_compose}" 'pids_limit: ${GRAFANA_PIDS_LIMIT}' \
    "Grafana process count is bounded"
  require_literal "${grafana_compose}" 'curl --max-time 5 -fsS' \
    "Grafana health probe bounds its HTTP wait"
  require_literal "${grafana_datasource}" 'uid: victorialogs-ds' \
    "Grafana data source has a stable UID"
  require_literal "${grafana_datasource}" 'maxLines: 500' \
    "Grafana log result size is bounded"
  require_literal "${grafana_datasource}" 'timeout: 60' \
    "Grafana data source timeout is explicit"
  require_literal "${grafana_datasource}" 'editable: false' \
    "Provisioned Grafana data source is immutable"
  validate_json_file "${grafana_dashboard}" \
    "Grafana log search dashboard is valid JSON"
  require_literal "${grafana_dashboard}" '"uid": "vvg-log-search"' \
    "Grafana log search dashboard has a stable UID"
  require_literal "${grafana_dashboard}" '"from": "now-15m"' \
    "Grafana log search dashboard defaults to 15 minutes"
  require_literal "${grafana_dashboard}" '"value": "jwxt-prod"' \
    "Grafana log search dashboard defaults to jwxt-prod"
  require_literal "${grafana_dashboard}" '"field": "namespace"' \
    "Grafana log search dashboard filters by namespace"
  require_literal "${grafana_dashboard}" '"field": "container"' \
    "Grafana log search dashboard filters by service container"
  require_literal "${grafana_dashboard}" '_msg:$message' \
    "Grafana log search dashboard uses the highlight-aware word filter"
  require_literal "${grafana_dashboard}" '"type": "marcusolsson-dynamictext-panel"' \
    "Grafana log search dashboard uses Business Text for the filter builder"
  forbid_regex "${grafana_dashboard}" '\| \$message' \
    "Grafana log search dashboard avoids unquoted pipe variables"
  forbid_regex "${grafana_dashboard}" 'message:~\$message' \
    "Grafana log search dashboard avoids regexp template interpolation"
  require_literal "${grafana_dashboard}" '"maxLines": 500' \
    "Grafana log details bound plugin response memory"
  require_literal "${grafana_dashboard}" '"queryType": "hits"' \
    "Grafana log trend uses the Explore Logs volume query path"
  require_literal "${grafana_dashboard}" '"supportingQueryType": "logsVolume"' \
    "Grafana log trend declares the Logs volume supporting query"
  require_literal "${grafana_dashboard}" '"maxDataPoints": 100' \
    "Grafana log trend keeps approximately 100 readable buckets"
  require_literal "${grafana_dashboard}" '"barWidthFactor": 0.6' \
    "Grafana log trend keeps balanced spacing between buckets"
  forbid_regex "${grafana_dashboard}" '"queryType": "statsRange"' \
    "Grafana log trend avoids sparse subpixel statsRange bars"
  require_literal "${grafana_dashboard}" '"value": "*"' \
    "Grafana log search dashboard uses the word-filter all value"
  require_literal "${grafana_dashboard}" '"query": "*"' \
    "Grafana message textbox defaults to all logs"
  if [[ "$(grep -Fc '"allValue": "*"' "${grafana_dashboard}")" == "4" ]]; then
    pass "Grafana log search dashboard bounds all multi-value filters"
  else
    fail "Grafana log search dashboard must set four allValue wildcards"
  fi
  require_literal "${grafana_dashboard}" '"valueSize": 28' \
    "Grafana log search dashboard uses compact stat values"
  require_literal "${grafana_dashboard}" '"fixedColor": "#1F78C1"' \
    "Grafana log search dashboard pins the Explore debug color"
  require_literal "${grafana_dashboard}" '"fixedColor": "#E24D42"' \
    "Grafana log search dashboard pins the Explore error color"
  if [[ "$(grep -Fc '"type": "row"' "${grafana_dashboard}")" == "2" ]]; then
    pass "Grafana log search dashboard has two compact collapse boundaries"
  else
    fail "Grafana log search dashboard must have exactly two row panels"
  fi
  if command -v node >/dev/null 2>&1; then
    node_command="node"
  elif command -v node.exe >/dev/null 2>&1; then
    node_command="node.exe"
  fi
  if [[ -n "${node_command}" ]] \
      && "${node_command}" scripts/validate-vvg-message-filter.mjs; then
    pass "Grafana dynamic message filter implementation validates"
  else
    fail "Grafana dynamic message filter implementation must pass its Node validator"
  fi

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

  require_literal "${mcp_compose}" 'version: "2.4"' \
    "VictoriaLogs MCP Compose stays compatible with the validated legacy host"
  require_literal "${mcp_env}" 'mcp-victorialogs:v1.9.0@sha256:af6afb6e36f3678e9d5096d155372a33b8c3e45e9a5de756129c6e5628dbff9d' \
    "VictoriaLogs MCP image uses a pinned release and digest"
  require_literal "${mcp_env}" 'vmauth:v1.151.0@sha256:047f7bdccff16df457db488e0e1fbc5b3fd15470c5b5ff5fa38a85d4d6bd71df' \
    "vmauth image uses a pinned release and digest"
  require_literal "${mcp_compose}" 'MCP_SERVER_MODE: http' \
    "VictoriaLogs MCP uses streamable HTTP mode"
  require_literal "${mcp_compose}" 'MCP_DISABLED_TOOLS: documentation,flags,facets,streams,stream_ids,stream_field_names,stream_field_values,stats_query_range' \
    "VictoriaLogs MCP exposes only the approved read-only tool set"
  forbid_regex "${mcp_compose}" 'MCP_PASSTHROUGH_HEADERS' \
    "VictoriaLogs MCP does not pass caller headers upstream"
  require_literal "${mcp_compose}" 'read_only: true' \
    "VictoriaLogs MCP services use read-only root filesystems"
  require_literal "${mcp_compose}" 'mem_limit: 256m' \
    "VictoriaLogs MCP memory usage is bounded"
  require_literal "${mcp_auth}" 'max_concurrent_requests: 1' \
    "VictoriaLogs MCP reserves only one backend query slot"
  require_literal "${mcp_auth}" 'limit=~([1-9]|[1-9][0-9]|[1-4][0-9][0-9]|500)' \
    "VictoriaLogs MCP preserves explicit log limits up to 500"
  require_literal "${mcp_auth}" '?limit=500&timeout=20s' \
    "VictoriaLogs MCP clamps missing or oversized log limits"
  require_literal "${mcp_auth}" '?limit=100&timeout=15s' \
    "VictoriaLogs MCP bounds field discovery"
  require_literal "${mcp_auth}" 'AccountID: __VL_ACCOUNT_ID__' \
    "vmauth fixes the VictoriaLogs account tenant"
  require_literal "${mcp_auth}" 'ProjectID: __VL_PROJECT_ID__' \
    "vmauth fixes the VictoriaLogs project tenant"
  forbid_regex "${mcp_auth}" '/(insert|flags|metrics)(/|\")' \
    "VictoriaLogs MCP proxy exposes no write or administrative backend paths"
  require_literal ".gitignore" 'docker-compose/mcp-victorialogs/vmauth/auth.yml' \
    "Rendered vmauth credentials are ignored"
  require_literal ".gitignore" '**/client-bearer-token' \
    "MCP client bearer tokens are ignored"

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

  if grep -n '^version:' docker-compose/*/docker-compose.yml \
      | grep -v '^docker-compose/mcp-victorialogs/docker-compose.yml:' >/dev/null; then
    fail "Compose files must not use the obsolete top-level version field"
  else
    pass "Compose files omit the obsolete top-level version field except the validated legacy MCP deployment"
  fi

  if bash scripts/validate-clickhouse-gateway.sh --static; then
    pass "Gateway ClickHouse static configuration validates"
  else
    fail "Gateway ClickHouse static configuration validates"
  fi

  if bash scripts/validate-automq.sh --static; then
    pass "AutoMQ static configuration validates"
  else
    fail "AutoMQ static configuration validates"
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
  local grafana_image
  local plugin_dir
  local plugin_version
  local text_plugin_version
  local plugin_list

  command -v docker >/dev/null 2>&1 || {
    printf 'docker is required for --runtime validation\n' >&2
    return 1
  }
  docker compose version

  for component in grafana victorialogs vector mcp-victorialogs; do
    docker compose \
      --env-file "docker-compose/${component}/env.example" \
      -f "docker-compose/${component}/docker-compose.yml" \
      config --quiet
    pass "${component} Compose configuration expands"
  done

  if [[ "${VVG_SKIP_GRAFANA_PLUGIN_BUNDLE:-0}" == "1" ]]; then
    printf 'SKIP: Grafana plugin bundle validation explicitly disabled by VVG_SKIP_GRAFANA_PLUGIN_BUNDLE=1\n'
  else
    grafana_image="$(sed -n 's/^GRAFANA_IMAGE=//p' docker-compose/grafana/env.example)"
    plugin_version="$(sed -n 's/^VICTORIALOGS_PLUGIN_VERSION=//p' docker-compose/grafana/env.example)"
    text_plugin_version="$(sed -n 's/^BUSINESS_TEXT_PLUGIN_VERSION=//p' docker-compose/grafana/env.example)"
    grafana_image="${grafana_image%$'\r'}"
    plugin_version="${plugin_version%$'\r'}"
    text_plugin_version="${text_plugin_version%$'\r'}"
    temp_dir="$(mktemp -d)"
    trap "chmod -R u+w -- '${temp_dir}' 2>/dev/null || true; rm -rf -- '${temp_dir}'" EXIT
    plugin_dir="${temp_dir}/plugins/releases/grafana13.2.0-vl0.31.0-text6.3.0"
    bash scripts/install-grafana-plugins.sh \
      docker-compose/grafana/env.example \
      "${plugin_dir}"
    mkdir -p "${temp_dir}/grafana-data"
    chmod 0777 "${temp_dir}/grafana-data"
    plugin_list="$(docker run --rm \
      -v "${temp_dir}/grafana-data:/var/lib/grafana" \
      -v "${plugin_dir}:/var/lib/grafana-plugins:ro" \
      --entrypoint grafana \
      "${grafana_image}" \
      cli --pluginsDir /var/lib/grafana-plugins plugins ls)"
    chmod -R u+w -- "${temp_dir}"
    rm -rf "${temp_dir}"
    trap - EXIT
    if grep -Fq "victoriametrics-logs-datasource @ ${plugin_version}" <<<"${plugin_list}"; then
      pass "External Grafana bundle exposes VictoriaLogs plugin ${plugin_version}"
    else
      printf '%s\n' "${plugin_list}" >&2
      printf 'Grafana plugin bundle does not contain the expected VictoriaLogs plugin version\n' >&2
      return 1
    fi
    if grep -Fq "marcusolsson-dynamictext-panel @ ${text_plugin_version}" <<<"${plugin_list}"; then
      pass "External Grafana bundle exposes Business Text plugin ${text_plugin_version}"
    else
      printf '%s\n' "${plugin_list}" >&2
      printf 'Grafana plugin bundle does not contain the expected Business Text plugin version\n' >&2
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

  bash scripts/validate-clickhouse-gateway.sh --runtime
  pass "Gateway ClickHouse runtime configuration validates"

  bash scripts/validate-automq.sh --runtime
  pass "AutoMQ runtime configuration validates"
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
