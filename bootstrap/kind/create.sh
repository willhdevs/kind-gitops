#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME="kind"
readonly CLUSTER_CONTEXT="kind-kind"
readonly EXPECTED_VERSION="v1.33.12"
readonly EXPECTED_NODES="3"
readonly READY_TIMEOUT="5m"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
CONFIG_FILE="${SCRIPT_DIR}/kind-config.yaml"
readonly CONFIG_FILE
RUNTIME=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

select_provider() {
  if command -v podman >/dev/null 2>&1; then
    export KIND_EXPERIMENTAL_PROVIDER=podman
    RUNTIME="podman"
    printf 'Using Podman as the Kind provider.\n'
  elif command -v docker >/dev/null 2>&1; then
    export KIND_EXPERIMENTAL_PROVIDER=docker
    RUNTIME="docker"
    printf 'Using Docker as the Kind provider.\n'
  else
    fail "no supported container runtime found; install Podman or Docker"
  fi
}

start_cluster_nodes() {
  local -a stopped_nodes=()

  mapfile -t stopped_nodes < <(
    "${RUNTIME}" ps --all \
      --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
      --filter status=exited \
      --format '{{.Names}}'
  )

  if ((${#stopped_nodes[@]} > 0)); then
    printf 'Starting %s stopped cluster node(s).\n' "${#stopped_nodes[@]}"
    "${RUNTIME}" start "${stopped_nodes[@]}" >/dev/null
  fi
}

wait_for_api() {
  for _ in {1..60}; do
    if kubectl --context "${CLUSTER_CONTEXT}" get nodes >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  fail "Kubernetes API for ${CLUSTER_NAME} did not become available"
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq -- "${CLUSTER_NAME}"
}

verify_cluster() {
  local actual_version
  local node_count
  local ready_count

  kubectl config get-contexts "${CLUSTER_CONTEXT}" --no-headers >/dev/null 2>&1 ||
    fail "cluster exists but kube context ${CLUSTER_CONTEXT} is missing"

  wait_for_api
  kubectl --context "${CLUSTER_CONTEXT}" wait \
    --for=condition=Ready nodes --all --timeout="${READY_TIMEOUT}" >/dev/null

  actual_version="$(
    kubectl --context "${CLUSTER_CONTEXT}" get --raw=/version |
      sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p'
  )"
  [[ -n "${actual_version}" ]] || fail "could not determine the Kubernetes server version"
  [[ "${actual_version}" == "${EXPECTED_VERSION}" ]] ||
    fail "cluster ${CLUSTER_NAME} runs Kubernetes ${actual_version}; expected ${EXPECTED_VERSION}; refusing to replace it"

  node_count="$(kubectl --context "${CLUSTER_CONTEXT}" get nodes --no-headers | wc -l | tr -d '[:space:]')"
  [[ "${node_count}" == "${EXPECTED_NODES}" ]] ||
    fail "cluster ${CLUSTER_NAME} has ${node_count} nodes; expected ${EXPECTED_NODES}; refusing to replace it"

  ready_count="$(kubectl --context "${CLUSTER_CONTEXT}" get nodes --no-headers | awk '$2 == "Ready" { count++ } END { print count + 0 }')"
  [[ "${ready_count}" == "${EXPECTED_NODES}" ]] ||
    fail "cluster ${CLUSTER_NAME} has ${ready_count}/${EXPECTED_NODES} Ready nodes"

  printf 'Cluster %s is ready: %s nodes running Kubernetes %s.\n' \
    "${CLUSTER_NAME}" "${EXPECTED_NODES}" "${EXPECTED_VERSION}"
}

main() {
  require_command kind
  require_command kubectl
  [[ -r "${CONFIG_FILE}" ]] || fail "Kind configuration not found: ${CONFIG_FILE}"
  select_provider

  if cluster_exists; then
    printf 'Cluster %s already exists; recovering and verifying it without replacing it.\n' "${CLUSTER_NAME}"
    start_cluster_nodes
    verify_cluster
    return
  fi

  kind create cluster --config "${CONFIG_FILE}" --wait "${READY_TIMEOUT}"
  verify_cluster
}

main "$@"
