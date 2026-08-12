# Kind GitOps

This repository defines a reproducible local Kubernetes environment with Kind
and hands its in-cluster configuration to Argo CD.

## Ownership boundary

Kind provisions the Kubernetes cluster itself.

After the initial bootstrap, Argo CD reconciles Kubernetes resources from
`clusters/local`, including its own installation. Provider processes such as
Kind and cloud-provider-kind remain outside GitOps.

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
the cluster to become ready, and refuses to replace an incompatible cluster. If
both Podman and Docker are installed, it uses whichever runtime owns the
existing cluster and refuses to continue if they contain distinct clusters
named `kind`.

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
`${GOPATH:-$HOME/go}/bin`, selects the runtime that owns the `kind` cluster, and
passes any additional arguments through to the controller.

Cloud Provider KIND provides LoadBalancer and native Ingress support without
mapping host ports directly to the control-plane node.

## Bootstrap Argo CD

After creating the Kind cluster, bootstrap Argo CD with one command:

```bash
./bootstrap/argocd/bootstrap.sh
```

The script requires the current Kubernetes context to be `kind-kind`. It
installs the standard non-HA Argo CD `v3.5.1` distribution, waits for its
controllers, and applies one root `Application`. The application follows the
`main` branch of this public repository and continuously reconciles
`clusters/local` with automated pruning and self-healing.

The Argo CD `v3.5.1` installation source is pinned to the full release commit in
both the bootstrap script and the cluster Kustomization. Re-running the
bootstrap command safely reapplies the same desired state and waits for the root
application to report `Synced` and `Healthy`; the Argo CD CLI and UI are not
required.

Verify the installation from the command line:

```bash
kubectl --context kind-kind --namespace argocd get applications.argoproj.io root
kubectl --context kind-kind --namespace argocd get deployments
kubectl --context kind-kind --namespace gitops-system get configmap reconciliation-smoke-test
```

## Development checks

Shell scripts use the style defined in `.editorconfig`. Run the same checks used
by GitHub Actions before pushing:

```bash
shfmt -d .
shellcheck bootstrap/**/*.sh
```

Use `shfmt -w .` to format shell scripts in place. CI runs on Ubuntu 26.04.
