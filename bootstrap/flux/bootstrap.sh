#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_CONTEXT="kind-kind-flux"
readonly FLUX_NAMESPACE="flux-system"
readonly FLUX_OPERATOR_VERSION="0.58.0"
readonly FLUX_OPERATOR_CHART="oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator"
readonly READY_TIMEOUT="5m"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly REPOSITORY_ROOT
FLUX_INSTANCE_FILE="${REPOSITORY_ROOT}/clusters/local/flux-system/flux-instance.yaml"
readonly FLUX_INSTANCE_FILE

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

kubectl_for_cluster() {
  kubectl --context "${CLUSTER_CONTEXT}" "$@"
}

diagnostics() {
  printf 'Flux bootstrap diagnostics:\n' >&2
  kubectl_for_cluster --namespace "${FLUX_NAMESPACE}" \
    get deployments,pods,fluxinstances,fluxreports,gitrepositories,kustomizations \
    --output=wide >&2 || true
  kubectl_for_cluster --namespace "${FLUX_NAMESPACE}" \
    describe fluxinstance/flux >&2 || true
}

verify_context() {
  local current_context

  kubectl config get-contexts "${CLUSTER_CONTEXT}" --no-headers >/dev/null 2>&1 ||
    fail "required Kubernetes context not found: ${CLUSTER_CONTEXT}"

  current_context="$(kubectl config current-context 2>/dev/null || true)"
  [[ "${current_context}" == "${CLUSTER_CONTEXT}" ]] ||
    fail "current Kubernetes context is ${current_context:-unset}; switch to ${CLUSTER_CONTEXT} before bootstrapping Flux"

  kubectl_for_cluster get --raw=/readyz >/dev/null 2>&1 ||
    fail "Kubernetes API for ${CLUSTER_CONTEXT} is not ready"
}

install_operator() {
  printf 'Installing Flux Operator v%s.\n' "${FLUX_OPERATOR_VERSION}"
  helm upgrade --install flux-operator "${FLUX_OPERATOR_CHART}" \
    --version "${FLUX_OPERATOR_VERSION}" \
    --namespace "${FLUX_NAMESPACE}" \
    --create-namespace \
    --kube-context "${CLUSTER_CONTEXT}" \
    --wait \
    --timeout "${READY_TIMEOUT}"

  kubectl_for_cluster wait --for=condition=Established \
    customresourcedefinition/fluxinstances.fluxcd.controlplane.io \
    --timeout="${READY_TIMEOUT}"
  kubectl_for_cluster --namespace "${FLUX_NAMESPACE}" wait \
    --for=condition=Available deployment/flux-operator \
    --timeout="${READY_TIMEOUT}"
}

configure_flux() {
  printf 'Applying the FluxInstance.\n'
  kubectl_for_cluster apply --server-side \
    --field-manager=flux-bootstrap \
    --filename "${FLUX_INSTANCE_FILE}"

  if ! kubectl_for_cluster --namespace "${FLUX_NAMESPACE}" wait \
    --for=condition=Ready fluxinstance/flux \
    --timeout="${READY_TIMEOUT}"; then
    diagnostics
    fail "FluxInstance did not become Ready"
  fi

  if ! kubectl_for_cluster --namespace "${FLUX_NAMESPACE}" wait \
    --for=condition=Ready \
    gitrepository/flux-system \
    kustomization/flux-system \
    --timeout="${READY_TIMEOUT}"; then
    diagnostics
    fail "Flux cluster sync did not become Ready"
  fi
}

verify_reconciliation() {
  local status

  kubectl_for_cluster --namespace "${FLUX_NAMESPACE}" get fluxreport/flux >/dev/null
  status="$(
    kubectl_for_cluster --namespace flux-smoke \
      get configmap reconciliation-smoke \
      --output=jsonpath='{.data.status}'
  )"
  [[ "${status}" == "reconciled" ]] ||
    fail "Flux smoke ConfigMap has status ${status:-missing}; expected reconciled"

  printf 'Flux Operator and Flux %s are ready and reconciling main.\n' "2.9.4"
}

main() {
  require_command helm
  require_command kubectl
  [[ -r "${FLUX_INSTANCE_FILE}" ]] ||
    fail "FluxInstance manifest not found: ${FLUX_INSTANCE_FILE}"

  verify_context
  install_operator
  configure_flux
  verify_reconciliation
}

main "$@"
