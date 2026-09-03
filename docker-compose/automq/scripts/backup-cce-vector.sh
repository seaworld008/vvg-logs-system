#!/usr/bin/env bash
set -euo pipefail

namespace="${VECTOR_NAMESPACE:-logging}"
efk_root="${CCE_EFK_ROOT:-/data/cce-huaweiCloud-manager/efk}"
timestamp="$(date +%Y%m%d%H%M%S)"

backup_pipeline() {
  local directory="$1"
  local daemonset="$2"
  local configmap="$3"
  local selector="$4"
  local source_manifest="$5"
  local backup_dir="${efk_root}/${directory}/backups/automq-pre-shadow-${timestamp}"
  local checkpoint_file="${backup_dir}/${daemonset}.checkpoints.sha256"

  umask 077
  mkdir -p "${backup_dir}"
  chmod 0700 "${efk_root}/${directory}/backups" "${backup_dir}"
  kubectl -n "${namespace}" get daemonset "${daemonset}" -o yaml \
    > "${backup_dir}/${daemonset}.daemonset.yaml"
  kubectl -n "${namespace}" get configmap "${configmap}" -o yaml \
    > "${backup_dir}/${configmap}.configmap.yaml"
  cp "${efk_root}/${directory}/${source_manifest}" \
    "${backup_dir}/${source_manifest}"

  : > "${checkpoint_file}"
  while read -r pod; do
    printf '%s\n' "${pod}" >> "${checkpoint_file}"
    kubectl -n "${namespace}" exec "${pod}" -- sh -c '
      find /var/lib/vector /var/lib/vector-gateway -type f 2>/dev/null |
        sort | while read -r file; do sha256sum "${file}"; done
    ' >> "${checkpoint_file}" 2>/dev/null || true
  done < <(kubectl -n "${namespace}" get pods -l "${selector}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

  (
    cd "${backup_dir}"
    sha256sum ./*.yaml ./*.sha256 > SHA256SUMS
  )
  chmod 0600 "${backup_dir}"/*
  printf 'Backup complete: %s\n' "${backup_dir}"
}

backup_pipeline vector-log vector-log vector-log-config app=vector-log \
  vector-k8s-containerd-cri.yaml
backup_pipeline vector-gateway vector-agent vector-agent-config-v058 app=vector \
  vector-k8s-with-new-fields.yaml
