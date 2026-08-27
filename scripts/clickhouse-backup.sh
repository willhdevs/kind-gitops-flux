#!/usr/bin/env bash

set -Eeuo pipefail

readonly NAMESPACE="telemetry"
readonly POD_SELECTOR="telemetry.willh.dev/component=clickhouse"
readonly DATABASE="flows"
readonly BACKUP_DIRECTORY="/var/lib/clickhouse/backups"

KUBE_CONTEXT=""
OUTPUT_PATH=""
CLICKHOUSE_POD=""
REMOTE_BACKUP=""
STAGING_PATH=""

usage() {
  cat <<'EOF'
Usage: clickhouse-backup.sh [--context CONTEXT] OUTPUT_PATH

Create a native ClickHouse backup of the flows database and save it to
OUTPUT_PATH. The active Kubernetes context is used when --context is omitted.

Options:
  --context CONTEXT  Kubernetes context to use
  -h, --help         Show this help
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

kubectl_for_cluster() {
  kubectl --context "${KUBE_CONTEXT}" "$@"
}

cleanup() {
  local status=$?

  if [[ -n "${REMOTE_BACKUP}" && -n "${CLICKHOUSE_POD}" ]]; then
    kubectl_for_cluster --namespace "${NAMESPACE}" exec "${CLICKHOUSE_POD}" -- \
      rm -f -- "${REMOTE_BACKUP}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${STAGING_PATH}" ]]; then
    rm -f -- "${STAGING_PATH}"
  fi

  exit "${status}"
}

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
    --context)
      (($# >= 2)) || fail "--context requires a value"
      [[ -z "${KUBE_CONTEXT}" ]] || fail "--context may only be specified once"
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 1)) || fail "exactly one output path is required"
      [[ -z "${OUTPUT_PATH}" ]] || fail "exactly one output path is required"
      OUTPUT_PATH="$1"
      shift
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "${OUTPUT_PATH}" ]] || fail "exactly one output path is required"
      OUTPUT_PATH="$1"
      shift
      ;;
    esac
  done

  [[ -n "${OUTPUT_PATH}" ]] || fail "an output path is required"
}

resolve_context() {
  if [[ -z "${KUBE_CONTEXT}" ]]; then
    KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null)" ||
      fail "could not determine the active Kubernetes context"
  fi
  [[ -n "${KUBE_CONTEXT}" ]] || fail "the active Kubernetes context is empty"
}

find_clickhouse_pod() {
  local -a pods=()

  mapfile -t pods < <(
    kubectl_for_cluster --namespace "${NAMESPACE}" get pods \
      --selector "${POD_SELECTOR}" \
      --field-selector status.phase=Running \
      --output jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  )

  ((${#pods[@]} == 1)) ||
    fail "expected exactly one running ClickHouse pod in namespace ${NAMESPACE}; found ${#pods[@]}"
  CLICKHOUSE_POD="${pods[0]}"
}

clickhouse_query() {
  kubectl_for_cluster --namespace "${NAMESPACE}" exec "${CLICKHOUSE_POD}" -- \
    clickhouse-client --user default --query "$1"
}

validate_output_path() {
  local output_directory

  [[ ! -e "${OUTPUT_PATH}" ]] || fail "output path already exists: ${OUTPUT_PATH}"
  output_directory="$(dirname -- "${OUTPUT_PATH}")"
  [[ -d "${output_directory}" ]] || fail "output directory does not exist: ${output_directory}"
  [[ -w "${output_directory}" ]] || fail "output directory is not writable: ${output_directory}"

  STAGING_PATH="$(mktemp "${OUTPUT_PATH}.tmp.XXXXXX")" ||
    fail "could not create a temporary file beside ${OUTPUT_PATH}"
}

main() {
  local backup_name

  parse_arguments "$@"
  require_command kubectl
  resolve_context
  validate_output_path
  find_clickhouse_pod
  clickhouse_query "SELECT 1" >/dev/null

  backup_name="flows-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}.zip"
  REMOTE_BACKUP="${BACKUP_DIRECTORY}/${backup_name}"

  printf 'Creating ClickHouse backup using context %s.\n' "${KUBE_CONTEXT}"
  clickhouse_query "BACKUP DATABASE ${DATABASE} TO File('${REMOTE_BACKUP}')"

  kubectl_for_cluster --namespace "${NAMESPACE}" exec "${CLICKHOUSE_POD}" -- \
    cat "${REMOTE_BACKUP}" >"${STAGING_PATH}"
  [[ -s "${STAGING_PATH}" ]] || fail "ClickHouse produced an empty backup archive"

  ln "${STAGING_PATH}" "${OUTPUT_PATH}" 2>/dev/null ||
    fail "output path was created while the backup was running: ${OUTPUT_PATH}"
  rm -f -- "${STAGING_PATH}"
  STAGING_PATH=""

  printf 'Backup saved to %s.\n' "${OUTPUT_PATH}"
}

trap cleanup EXIT
main "$@"
