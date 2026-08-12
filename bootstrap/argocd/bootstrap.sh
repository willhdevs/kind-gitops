#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_CONTEXT="kind-kind"
readonly ARGOCD_NAMESPACE="argocd"
readonly ARGOCD_VERSION="v3.5.1"
readonly ARGOCD_COMMIT="109ca7ca71139e514114499d294a492e7910a965"
readonly ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_COMMIT}/manifests/install.yaml"
readonly READY_TIMEOUT="5m"
readonly APPLICATION_TIMEOUT_SECONDS="600"
readonly POLL_INTERVAL_SECONDS="5"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT_APPLICATION="${SCRIPT_DIR}/root-application.yaml"
readonly ROOT_APPLICATION

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

verify_context() {
  local current_context

  kubectl config get-contexts "${CLUSTER_CONTEXT}" --no-headers >/dev/null 2>&1 ||
    fail "required Kubernetes context not found: ${CLUSTER_CONTEXT}"

  current_context="$(kubectl config current-context 2>/dev/null || true)"
  [[ "${current_context}" == "${CLUSTER_CONTEXT}" ]] ||
    fail "current Kubernetes context is ${current_context:-unset}; switch to ${CLUSTER_CONTEXT} before bootstrapping Argo CD"

  kubectl --context "${CLUSTER_CONTEXT}" get --raw=/readyz >/dev/null 2>&1 ||
    fail "Kubernetes API for ${CLUSTER_CONTEXT} is not ready"
}

application_diagnostics() {
  printf 'Argo CD root application did not become Synced and Healthy.\n' >&2
  kubectl --context "${CLUSTER_CONTEXT}" --namespace "${ARGOCD_NAMESPACE}" \
    describe application root >&2 || true
  kubectl --context "${CLUSTER_CONTEXT}" --namespace "${ARGOCD_NAMESPACE}" \
    get pods --output=wide >&2 || true
}

wait_for_application() {
  local deadline
  local health=""
  local sync=""

  deadline="$((SECONDS + APPLICATION_TIMEOUT_SECONDS))"
  while ((SECONDS < deadline)); do
    sync="$(
      kubectl --context "${CLUSTER_CONTEXT}" --namespace "${ARGOCD_NAMESPACE}" \
        get application root --output=jsonpath='{.status.sync.status}' 2>/dev/null || true
    )"
    health="$(
      kubectl --context "${CLUSTER_CONTEXT}" --namespace "${ARGOCD_NAMESPACE}" \
        get application root --output=jsonpath='{.status.health.status}' 2>/dev/null || true
    )"

    if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
      printf 'Root application is Synced and Healthy.\n'
      return
    fi

    printf 'Waiting for root application (sync=%s, health=%s).\n' \
      "${sync:-Unknown}" "${health:-Unknown}"
    sleep "${POLL_INTERVAL_SECONDS}"
  done

  application_diagnostics
  return 1
}

main() {
  require_command kubectl
  [[ -r "${ROOT_APPLICATION}" ]] || fail "root Application not found: ${ROOT_APPLICATION}"
  verify_context

  kubectl --context "${CLUSTER_CONTEXT}" create namespace "${ARGOCD_NAMESPACE}" \
    --dry-run=client --output=yaml |
    kubectl --context "${CLUSTER_CONTEXT}" apply --server-side --field-manager=argocd-bootstrap -f -

  printf 'Installing Argo CD %s.\n' "${ARGOCD_VERSION}"
  kubectl --context "${CLUSTER_CONTEXT}" --namespace "${ARGOCD_NAMESPACE}" \
    apply --server-side --force-conflicts --field-manager=argocd-bootstrap \
    --filename "${ARGOCD_INSTALL_URL}"

  kubectl --context "${CLUSTER_CONTEXT}" wait \
    --for=condition=Established customresourcedefinition/applications.argoproj.io \
    --timeout="${READY_TIMEOUT}"
  kubectl --context "${CLUSTER_CONTEXT}" --namespace "${ARGOCD_NAMESPACE}" wait \
    --for=condition=Available deployment --all --timeout="${READY_TIMEOUT}"
  kubectl --context "${CLUSTER_CONTEXT}" --namespace "${ARGOCD_NAMESPACE}" rollout status \
    statefulset/argocd-application-controller --timeout="${READY_TIMEOUT}"

  printf 'Applying the root Argo CD Application.\n'
  kubectl --context "${CLUSTER_CONTEXT}" --namespace "${ARGOCD_NAMESPACE}" \
    apply --server-side --field-manager=argocd-bootstrap --filename "${ROOT_APPLICATION}"

  wait_for_application
}

main "$@"
