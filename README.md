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
the configured Kubernetes version from the same content-addressed image.

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
- Kubernetes: version pinned in `bootstrap/kind/kind-config.yaml`

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

The Fleet Server Agent receives NetFlow/IPFIX through the
`fleet-server-netflow` LoadBalancer on `2055/UDP`. Route the exporter or its
tunnel to the address or host port assigned by cloud-provider-kind.

## Provide the abuse.ch credential

Before Argo CD reconciles the Elastic stack, create Secret
`elastic-stack/abusech-api-credentials` with the abuse.ch Auth-Key in key
`auth-key`. The key is consumed by Kibana at startup, so restart Kibana after
rotating the Secret.

## Bootstrap Argo CD

After creating the Kind cluster, bootstrap Argo CD with one command:

```bash
./bootstrap/argocd/bootstrap.sh
```

The script requires the current Kubernetes context to be `kind-kind`. It
installs the pinned standard non-HA Argo CD distribution, waits for its
controllers, and applies one root `Application`. The application follows the
`main` branch of this public repository and continuously reconciles
`clusters/local` with automated pruning and self-healing.

The Argo CD installation source is pinned to the full release commit in
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

## Monitor the cluster

The root application reconciles Prometheus in the `monitoring` namespace.

Verify reconciliation, workloads, and storage:

```bash
kubectl --context kind-kind --namespace argocd get applications.argoproj.io root monitoring
kubectl --context kind-kind --namespace monitoring get deployments,statefulsets,pods
kubectl --context kind-kind --namespace monitoring get persistentvolumeclaims
kubectl --context kind-kind --namespace argocd get servicemonitors.monitoring.coreos.com
```

Both Argo CD applications should report `Synced` and `Healthy`, the monitoring
workloads should be ready, and the Prometheus claim should be `Bound` with the
`standard` storage class and a 5 GiB request.

Open the Prometheus web UI locally:

```bash
kubectl --context kind-kind --namespace monitoring port-forward service/monitoring-kube-prometheus-prometheus 9090:9090
```

Visit <http://localhost:9090/targets> and confirm the expected targets are
healthy.

## Use the Elastic stack

ECK manages Elasticsearch, Kibana, and a single-replica Fleet Server, which is
the stack's only Elastic Agent. Kibana initializes Fleet declaratively with
the `elastic_agent`, `fleet_server`, NetFlow, and abuse.ch packages and the
managed `eck-fleet-server` policy. NetFlow listens on `0.0.0.0:2055/UDP`.
Only the ThreatFox abuse.ch stream is enabled. Elasticsearch uses persistent
storage, and Prometheus scrapes the ECK operator.

The Elasticsearch node uses a fixed 512 MiB JVM heap. Application index
templates must set `index.number_of_replicas` to `0`.

ECK secures local endpoints with generated credentials and TLS. Retrieve the
generated `elastic` user password before connecting:

```bash
kubectl --context kind-kind --namespace elastic-stack get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}{{"\n"}}'
```

In separate terminals, forward Elasticsearch and Kibana locally:

```bash
kubectl --context kind-kind --namespace elastic-stack port-forward service/elasticsearch-es-http 9200:9200
kubectl --context kind-kind --namespace elastic-stack port-forward service/kibana-kb-http 5601:5601
```

Elasticsearch is available at <https://localhost:9200> and Kibana at
<https://localhost:5601>. Local tools may require an insecure TLS option unless
you export and trust the ECK-generated CA. Sign in to Kibana as `elastic` with
the generated password.

### Verify NetFlow and ThreatFox ingestion

Use `data_stream.dataset: "netflow.log"` and
`data_stream.dataset: "ti_abusech.threatfox"` against `logs-*`. Active,
unexpired indicators are written to `logs-ti_abusech_latest.dest_threatfox*`;
verify correlation fields with
`threat.indicator.ip:* or threat.indicator.url.domain:*`.

NetFlow v9 and IPFIX require an exporter template before records can be decoded,
so ingestion may pause until the next template refresh after a restart.

## Development checks

Run the same lint and manifest checks used by GitHub Actions before pushing:

```bash
./scripts/check.sh
```

The script derives the Kubernetes schema version from the digest-pinned Kind
node image. It uses a local `kubeconform` binary when available, or runs the
pinned container image with Podman or Docker. Use `shfmt -w .` to format shell
scripts in place. Kubeconform skips resources whose schemas are unavailable;
Helm rendering and cluster-side validation are outside the scope of these
checks.
