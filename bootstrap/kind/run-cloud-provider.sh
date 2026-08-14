#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME="kind-flux"
RUNTIME=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

find_cloud_provider_kind() {
  local go_bin

  if command -v cloud-provider-kind >/dev/null 2>&1; then
    command -v cloud-provider-kind
    return
  fi

  go_bin="${GOPATH:-${HOME}/go}/bin/cloud-provider-kind"
  [[ -x "${go_bin}" ]] ||
    fail "cloud-provider-kind not found on PATH or at ${go_bin}"
  printf '%s\n' "${go_bin}"
}

runtime_cluster_id() {
  local runtime="$1"

  "${runtime}" ps --all \
    --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.ID}} {{.Names}}' 2>/dev/null |
    awk -v name="${CLUSTER_NAME}-control-plane" '$2 == name { print $1; exit }'
}

runtime_is_available() {
  command -v "$1" >/dev/null 2>&1 && "$1" ps >/dev/null 2>&1
}

select_provider() {
  local docker_available=false
  local docker_cluster_id=""
  local podman_available=false
  local podman_cluster_id=""

  runtime_is_available podman && podman_available=true
  runtime_is_available docker && docker_available=true
  ${podman_available} && podman_cluster_id="$(runtime_cluster_id podman)"
  ${docker_available} && docker_cluster_id="$(runtime_cluster_id docker)"

  if [[ -n "${podman_cluster_id}" && -n "${docker_cluster_id}" && "${podman_cluster_id}" != "${docker_cluster_id}" ]]; then
    fail "cluster ${CLUSTER_NAME} exists in both Podman and Docker; remove the duplicate before continuing"
  elif [[ -n "${podman_cluster_id}" ]]; then
    RUNTIME="podman"
  elif [[ -n "${docker_cluster_id}" ]]; then
    RUNTIME="docker"
  else
    fail "cluster ${CLUSTER_NAME} was not found in Podman or Docker; create it before starting cloud-provider-kind"
  fi

  export KIND_EXPERIMENTAL_PROVIDER="${RUNTIME}"
  printf 'Using %s as the cloud-provider-kind runtime.\n' "${RUNTIME^}"
}

main() {
  local cloud_provider_kind

  cloud_provider_kind="$(find_cloud_provider_kind)"
  select_provider

  if pgrep -u "$(id -u)" -f '(^|/)cloud-provider-kind([[:space:]]|$)' >/dev/null 2>&1; then
    fail "cloud-provider-kind is already running for this user"
  fi

  printf 'Starting cloud-provider-kind; press Ctrl-C to stop it.\n'
  exec "${cloud_provider_kind}" --enable-lb-port-mapping "$@"
}

main "$@"
