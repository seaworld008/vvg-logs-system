#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${1:-${repo_root}/docker-compose/grafana/.env}"
target_override="${2:-}"

[[ -f "${env_file}" ]] || {
  printf 'Grafana env file not found: %s\n' "${env_file}" >&2
  exit 1
}

read_env() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  value="${value%$'\r'}"
  [[ -n "${value}" ]] || {
    printf 'Required value %s is missing from %s\n' "${key}" "${env_file}" >&2
    exit 1
  }
  printf '%s' "${value}"
}

read_env_optional() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  value="${value%$'\r'}"
  printf '%s' "${value}"
}

GRAFANA_IMAGE="$(read_env GRAFANA_IMAGE)"
VICTORIALOGS_PLUGIN_VERSION="$(read_env VICTORIALOGS_PLUGIN_VERSION)"
BUSINESS_TEXT_PLUGIN_VERSION="$(read_env BUSINESS_TEXT_PLUGIN_VERSION)"
GRAFANA_EXTRA_PLUGINS="$(read_env_optional GRAFANA_EXTRA_PLUGINS)"
configured_target="$(read_env GRAFANA_PLUGINS_DIR)"
target_dir="${target_override:-${configured_target}}"

extra_plugins=()
if [[ -n "${GRAFANA_EXTRA_PLUGINS}" ]]; then
  IFS=',' read -r -a extra_plugins <<<"${GRAFANA_EXTRA_PLUGINS}"
  for plugin_spec in "${extra_plugins[@]}"; do
    [[ "${plugin_spec}" =~ ^[a-z0-9_-]+@[0-9][A-Za-z0-9._-]*$ ]] || {
      printf 'Invalid GRAFANA_EXTRA_PLUGINS entry: %s\n' "${plugin_spec}" >&2
      exit 1
    }
    [[ "${plugin_spec}" == "grafana-clickhouse-datasource@4.5.1" ]] || {
      printf 'Unsupported extra Grafana plugin: %s\n' "${plugin_spec}" >&2
      exit 1
    }
  done
fi

case "${target_dir}" in
  /*/plugins/releases/*) ;;
  *)
    printf 'Plugin target must be an absolute versioned path below plugins/releases: %s\n' \
      "${target_dir}" >&2
    exit 1
    ;;
esac

parent_dir="$(dirname "${target_dir}")"
bundle_name="$(basename "${target_dir}")"
install -d -m 0755 "${parent_dir}"

list_plugins() {
  local directory="$1"
  docker run --rm \
    -v "${directory}:/var/lib/grafana-plugins:ro" \
    --entrypoint grafana \
    "${GRAFANA_IMAGE}" \
    cli --pluginsDir /var/lib/grafana-plugins plugins ls
}

validate_plugins() {
  local directory="$1"
  local output
  output="$(list_plugins "${directory}")"
  grep -Fq "victoriametrics-logs-datasource @ ${VICTORIALOGS_PLUGIN_VERSION}" \
    <<<"${output}" || {
      printf '%s\n' "${output}" >&2
      printf 'VictoriaLogs plugin version mismatch in %s\n' "${directory}" >&2
      exit 1
    }
  grep -Fq "marcusolsson-dynamictext-panel @ ${BUSINESS_TEXT_PLUGIN_VERSION}" \
    <<<"${output}" || {
      printf '%s\n' "${output}" >&2
      printf 'Business Text plugin version mismatch in %s\n' "${directory}" >&2
      exit 1
    }
  for plugin_spec in "${extra_plugins[@]}"; do
    plugin_id="${plugin_spec%@*}"
    plugin_version="${plugin_spec##*@}"
    grep -Fq "${plugin_id} @ ${plugin_version}" <<<"${output}" || {
      printf '%s\n' "${output}" >&2
      printf 'Extra plugin version mismatch in %s: %s\n' \
        "${directory}" "${plugin_spec}" >&2
      exit 1
    }
  done
  printf '%s\n' "${output}"
}

if [[ -d "${target_dir}" ]]; then
  [[ -f "${target_dir}/SHA256SUMS" ]] || {
    printf 'Existing plugin bundle has no SHA256SUMS: %s\n' "${target_dir}" >&2
    exit 1
  }
  (
    cd "${target_dir}"
    sha256sum -c SHA256SUMS
  )
  validate_plugins "${target_dir}"
  printf 'Plugin bundle already exists and validates: %s\n' "${target_dir}"
  exit 0
fi

stage_dir="$(mktemp -d "${parent_dir}/.${bundle_name}.staging.XXXXXX")"
installer_uid="$(id -u)"
installer_gid="$(id -g)"
cleanup() {
  if [[ -n "${stage_dir:-}" && -d "${stage_dir}" ]]; then
    rm -rf -- "${stage_dir}"
  fi
}
trap cleanup EXIT
chmod 0777 "${stage_dir}"

docker run --rm \
  --user "${installer_uid}:${installer_gid}" \
  -v "${stage_dir}:/var/lib/grafana-plugins" \
  --entrypoint grafana \
  "${GRAFANA_IMAGE}" \
  cli --pluginsDir /var/lib/grafana-plugins \
  plugins install victoriametrics-logs-datasource "${VICTORIALOGS_PLUGIN_VERSION}"

docker run --rm \
  --user "${installer_uid}:${installer_gid}" \
  -v "${stage_dir}:/var/lib/grafana-plugins" \
  --entrypoint grafana \
  "${GRAFANA_IMAGE}" \
  cli --pluginsDir /var/lib/grafana-plugins \
  plugins install marcusolsson-dynamictext-panel "${BUSINESS_TEXT_PLUGIN_VERSION}"

for plugin_spec in "${extra_plugins[@]}"; do
  plugin_id="${plugin_spec%@*}"
  plugin_version="${plugin_spec##*@}"
  docker run --rm \
    --user "${installer_uid}:${installer_gid}" \
    -v "${stage_dir}:/var/lib/grafana-plugins" \
    --entrypoint grafana \
    "${GRAFANA_IMAGE}" \
    cli --pluginsDir /var/lib/grafana-plugins \
    plugins install "${plugin_id}" "${plugin_version}"
done

validate_plugins "${stage_dir}" >/dev/null
printf 'grafana_image=%s\nvictorialogs_plugin=%s\nbusiness_text_plugin=%s\n' \
  "${GRAFANA_IMAGE}" \
  "${VICTORIALOGS_PLUGIN_VERSION}" \
  "${BUSINESS_TEXT_PLUGIN_VERSION}" \
  > "${stage_dir}/BUNDLE-MANIFEST"
for plugin_spec in "${extra_plugins[@]}"; do
  printf 'extra_plugin=%s\n' "${plugin_spec}" >> "${stage_dir}/BUNDLE-MANIFEST"
done
(
  cd "${stage_dir}"
  find . -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    > SHA256SUMS
  sha256sum -c SHA256SUMS
)
chmod -R a-w "${stage_dir}"
mv "${stage_dir}" "${target_dir}"
stage_dir=""

validate_plugins "${target_dir}"
printf 'Plugin bundle published: %s\n' "${target_dir}"
