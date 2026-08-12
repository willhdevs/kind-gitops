# Kind GitOps

This repository defines a reproducible local Kubernetes environment with Kind.

## Ownership boundary

Kind provisions the Kubernetes cluster itself.

## Prerequisites

- Kind (tested with `v0.31.0`)
- kubectl (tested with `v1.35.7`)
- cloud-provider-kind
- Podman or Docker (tested with Podman `v5.8.4`)

The Kind node image is pinned in the cluster configuration, so every node runs
Kubernetes `v1.33.12` from the same content-addressed image.

## Create the cluster

From anywhere, run the kind bootstrap script:

```bash
./bootstrap/kind/create.sh
```

The script checks its prerequisites, and creates the
cluster exclusively from `bootstrap/kind/kind-config.yaml`. If a cluster named
`kind` already exists, the script starts any stopped node containers, waits for
the cluster to become ready, and refuses to replace an incompatible cluster.

Expected result:

- Kind cluster: `kind`
- kubectl context: `kind-kind`
- Topology: one control-plane and two worker nodes
- Kubernetes: `v1.33.12`

## Run the local cloud provider

In a separate terminal, run:

```bash
./bootstrap/kind/run-cloud-provider.sh
```

The launcher runs `cloud-provider-kind` in the foreground so its logs and
lifecycle remain visible. It discovers the binary on `PATH` or under
`${GOPATH:-$HOME/go}/bin`, prefers Podman when both supported runtimes are
installed, and passes any additional arguments through to the controller.

Cloud Provider KIND provides LoadBalancer and native Ingress support without
mapping host ports directly to the control-plane node.

## Development checks

Shell scripts use the style defined in `.editorconfig`. Run the same checks used
by GitHub Actions before pushing:

```bash
shfmt -d .
shellcheck bootstrap/**/*.sh
```

Use `shfmt -w .` to format shell scripts in place. CI runs on Ubuntu 26.04.
