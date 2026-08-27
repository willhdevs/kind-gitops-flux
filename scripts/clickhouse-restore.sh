#!/usr/bin/env bash

set -Eeuo pipefail

readonly NAMESPACE="telemetry"
readonly POD_SELECTOR="telemetry.willh.dev/component=clickhouse"
readonly DATABASE="flows"
readonly BACKUP_DIRECTORY="/var/lib/clickhouse/backups"

KUBE_CONTEXT=""
INPUT_PATH=""
REPLACE=false
CLICKHOUSE_POD=""
REMOTE_BACKUP=""

usage() {
  cat <<'EOF'
Usage: clickhouse-restore.sh [--context CONTEXT] [--replace] INPUT_PATH

Restore the flows database from a native ClickHouse backup archive. The active
Kubernetes context is used when --context is omitted. A populated flows database
is never replaced unless --replace is supplied.

Options:
  --context CONTEXT  Kubernetes context to use
  --replace          Replace a populated flows database
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
    --replace)
      ${REPLACE} && fail "--replace may only be specified once"
      REPLACE=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 1)) || fail "exactly one input path is required"
      [[ -z "${INPUT_PATH}" ]] || fail "exactly one input path is required"
      INPUT_PATH="$1"
      shift
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "${INPUT_PATH}" ]] || fail "exactly one input path is required"
      INPUT_PATH="$1"
      shift
      ;;
    esac
  done

  [[ -n "${INPUT_PATH}" ]] || fail "an input path is required"
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

database_exists() {
  [[ "$(clickhouse_query "SELECT count() FROM system.databases WHERE name = '${DATABASE}'")" == "1" ]]
}

database_is_empty() {
  local summary
  local unknown_table_count
  local total_rows

  summary="$(
    clickhouse_query \
      "SELECT coalesce(sum(total_rows), 0), countIf(total_rows IS NULL) FROM system.tables WHERE database = '${DATABASE}' FORMAT TSVRaw"
  )"
  IFS=$'\t' read -r total_rows unknown_table_count <<<"${summary}"

  [[ "${total_rows}" =~ ^[0-9]+$ && "${unknown_table_count}" =~ ^[0-9]+$ ]] ||
    fail "could not determine whether database ${DATABASE} is empty"
  [[ "${total_rows}" == "0" && "${unknown_table_count}" == "0" ]]
}

validate_input_path() {
  [[ -f "${INPUT_PATH}" ]] || fail "input path is not a regular file: ${INPUT_PATH}"
  [[ -r "${INPUT_PATH}" ]] || fail "input path is not readable: ${INPUT_PATH}"
  [[ -s "${INPUT_PATH}" ]] || fail "input archive is empty: ${INPUT_PATH}"
}

main() {
  local backup_name

  parse_arguments "$@"
  require_command kubectl
  resolve_context
  validate_input_path
  find_clickhouse_pod
  clickhouse_query "SELECT 1" >/dev/null

  printf '%s\n' \
    'Warning: this script does not stop Telegraf or Flux. Ensure no ingestion occurs during the restore.' >&2

  if database_exists && ! database_is_empty && ! ${REPLACE}; then
    fail "database ${DATABASE} contains data or tables whose row count cannot be determined; use --replace to replace it"
  fi

  backup_name="flows-restore-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}.zip"
  REMOTE_BACKUP="${BACKUP_DIRECTORY}/${backup_name}"

  printf 'Uploading backup archive using context %s.\n' "${KUBE_CONTEXT}"
  kubectl_for_cluster --namespace "${NAMESPACE}" exec --stdin "${CLICKHOUSE_POD}" -- \
    sh -c "umask 077; cat >\"\$1\"" sh "${REMOTE_BACKUP}" <"${INPUT_PATH}"

  clickhouse_query "DROP DATABASE IF EXISTS ${DATABASE} SYNC"
  clickhouse_query "RESTORE DATABASE ${DATABASE} FROM File('${REMOTE_BACKUP}')"

  printf 'Database %s restored from %s.\n' "${DATABASE}" "${INPUT_PATH}"
}

trap cleanup EXIT
main "$@"
