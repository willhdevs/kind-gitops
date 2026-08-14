#!/usr/bin/env bash

set -Eeuo pipefail

readonly KUBECONFORM_IMAGE="ghcr.io/yannh/kubeconform@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_ROOT

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

kubernetes_version() {
  local -a versions=()

  mapfile -t versions < <(
    sed -n 's|^[[:space:]]*image: kindest/node:\(v[^@]*\)@sha256:.*|\1|p' \
      "${REPOSITORY_ROOT}/bootstrap/kind/kind-config.yaml" |
      sort -u
  )

  ((${#versions[@]} == 1)) ||
    fail "kind configuration must pin exactly one Kubernetes version"
  printf '%s\n' "${versions[0]#v}"
}

container_runtime() {
  local runtime

  for runtime in podman docker; do
    if command -v "${runtime}" >/dev/null 2>&1 && "${runtime}" info >/dev/null 2>&1; then
      printf '%s\n' "${runtime}"
      return
    fi
  done

  fail "kubeconform is not installed and no available Podman or Docker runtime was found"
}

check_yaml() {
  require_command yamllint
  yamllint --strict "${REPOSITORY_ROOT}"
}

check_kubernetes() (
  local -a runtime_arguments=(run --rm)
  local kubernetes_version
  local rendered_manifest
  local runtime

  require_command kubectl
  kubernetes_version="$(kubernetes_version)"
  rendered_manifest="$(mktemp "${REPOSITORY_ROOT}/.kubeconform-rendered.XXXXXX.yaml")"
  trap 'rm -f -- "${rendered_manifest}"' EXIT

  kubectl kustomize "${REPOSITORY_ROOT}/clusters/local" >"${rendered_manifest}"

  if command -v kubeconform >/dev/null 2>&1; then
    kubeconform \
      -strict \
      -ignore-missing-schemas \
      -summary \
      -kubernetes-version "${kubernetes_version}" \
      "${rendered_manifest}" \
      "${REPOSITORY_ROOT}/bootstrap/argocd/root-application.yaml"
    return
  fi

  runtime="$(container_runtime)"
  if [[ "${runtime}" == "podman" ]]; then
    runtime_arguments+=(--security-opt label=disable)
  fi
  chmod 0644 "${rendered_manifest}"
  "${runtime}" "${runtime_arguments[@]}" \
    --volume "${REPOSITORY_ROOT}:/workspace:ro" \
    --workdir /workspace \
    "${KUBECONFORM_IMAGE}" \
    -strict \
    -ignore-missing-schemas \
    -summary \
    -kubernetes-version "${kubernetes_version}" \
    "$(basename -- "${rendered_manifest}")" \
    bootstrap/argocd/root-application.yaml
)

check_shell() {
  require_command shellcheck
  require_command shfmt
  shopt -s globstar
  shfmt -d "${REPOSITORY_ROOT}"
  shellcheck "${REPOSITORY_ROOT}"/bootstrap/**/*.sh "${REPOSITORY_ROOT}"/scripts/**/*.sh
}

usage() {
  printf 'Usage: %s [all|yaml|kubernetes|shell]\n' "${0##*/}" >&2
  exit 2
}

main() {
  case "${1:-all}" in
  all)
    check_yaml
    check_kubernetes
    check_shell
    ;;
  yaml)
    check_yaml
    ;;
  kubernetes)
    check_kubernetes
    ;;
  shell)
    check_shell
    ;;
  *)
    usage
    ;;
  esac
}

main "$@"
