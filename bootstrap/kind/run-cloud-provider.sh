#!/usr/bin/env bash

set -Eeuo pipefail

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

select_provider() {
  if command -v podman >/dev/null 2>&1; then
    export KIND_EXPERIMENTAL_PROVIDER=podman
    printf 'Using Podman as the cloud-provider-kind runtime.\n'
  elif command -v docker >/dev/null 2>&1; then
    export KIND_EXPERIMENTAL_PROVIDER=docker
    printf 'Using Docker as the cloud-provider-kind runtime.\n'
  else
    fail "no supported container runtime found; install Podman or Docker"
  fi
}

main() {
  local cloud_provider_kind

  cloud_provider_kind="$(find_cloud_provider_kind)"
  select_provider

  if pgrep -u "$(id -u)" -f '(^|/)cloud-provider-kind([[:space:]]|$)' >/dev/null 2>&1; then
    fail "cloud-provider-kind is already running for this user"
  fi

  printf 'Starting cloud-provider-kind; press Ctrl-C to stop it.\n'
  exec "${cloud_provider_kind}" "$@"
}

main "$@"
