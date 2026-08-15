# kind-gitops-flux

This repository defines a local Kubernetes environment with
[kind](https://kind.sigs.k8s.io/), Docker or Podman, and
[cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind).

## Phase 1: Local cluster bootstrap

Phase 1 creates the `kind-flux` cluster and starts the local cloud provider.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Docker](https://docs.docker.com/engine/install/) or
  [Podman](https://podman.io/docs/installation)
- [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind/releases)

## Create the cluster

```bash
./bootstrap/kind/create.sh
```

The script creates the cluster from
`bootstrap/kind/kind-config.yaml`. If `kind-flux` already exists, it reuses the
existing cluster, ensures it is running, matching the runtime it was created with.
A new cluster uses Podman when available, otherwise Docker.

Cluster status:

```bash
kubectl --context kind-kind-flux get nodes
```

## Run the local cloud provider

```bash
./bootstrap/kind/run-cloud-provider.sh
```

## Phase 2: Flux bootstrap

Phase 2 installs Flux Operator and applies a `FluxInstance`. The instance
reconciles `clusters/local` from the public `main` branch.

Bootstrap:

```bash
./bootstrap/flux/bootstrap.sh
```

The script installs the pinned operator OCI chart, applies the `FluxInstance`,
waits for Git reconciliation, and checks the smoke ConfigMap. Re-running it
repairs or recovers the installation.

Status:

```bash
helm --kube-context kind-kind-flux --namespace flux-system status flux-operator
kubectl --context kind-kind-flux --namespace flux-system \
  get fluxinstances,fluxreports
kubectl --context kind-kind-flux --namespace flux-system \
  get gitrepositories,kustomizations
kubectl --context kind-kind-flux --namespace flux-system get deployments
```

Immediate source and Kustomization reconciliation:

```bash
requested_at="$(date +%s)"
kubectl --context kind-kind-flux --namespace flux-system annotate --overwrite \
  gitrepository/flux-system \
  "reconcile.fluxcd.io/requestedAt=${requested_at}"
kubectl --context kind-kind-flux --namespace flux-system annotate --overwrite \
  kustomization/flux-system \
  "reconcile.fluxcd.io/requestedAt=${requested_at}"
```

Flux upgrades are declared in `spec.distribution.version`. Flux Operator
upgrades use the chart version pinned by the bootstrap script.

## Monitoring

Flux reconciles the standard `kube-prometheus-stack` in the `monitoring`
namespace. Prometheus uses persistent storage, Grafana is exposed through
cloud-provider-kind, and Alertmanager retains its default local configuration
without an external receiver.

The controller manager, scheduler, etcd, and kube-proxy monitors are disabled
because their metrics endpoints are not reachable from Prometheus in kind.
Flux metrics and dashboards come from the Flux Operator project's official
monitoring configuration, pinned to an immutable upstream commit. Declarative
NetFlow / IPFIX dashboards are provisioned in `clusters/local/monitoring/dashboards/`.

The chart installs its CRDs using Helm's standard CRD mechanism. Removing the
Helm release leaves those CRDs installed; deleting a monitoring CRD also deletes
every custom resource stored under that API.

## Flow telemetry

Status:

```bash
kubectl --context kind-kind-flux --namespace telemetry \
  get service telegraf-ipfix
kubectl --context kind-kind-flux --namespace telemetry \
  get keeperclusters,clickhouseclusters,pods,services,persistentvolumeclaims
```

ClickHouse shell:

```bash
clickhouse_pod="$(kubectl --context kind-kind-flux --namespace telemetry \
  get pods --selector telemetry.willh.dev/component=clickhouse \
  --output jsonpath='{.items[0].metadata.name}')"
kubectl --context kind-kind-flux --namespace telemetry \
  exec --stdin --tty "${clickhouse_pod}" -- \
  clickhouse-client --user grafana_reader --database flows
```

Grafana Explore datasource: `clickhouse-telemetry`

Pre-provisioned Grafana Dashboards (Folder: `Network`):
- **Network Traffic Overview & Top Talkers** (`/d/netflow-overview`)
- **Flow Explorer & Granular Drill-Down** (`/d/flow-explorer`)

Recent records:

```sql
SELECT *
FROM flows.raw
ORDER BY received_at DESC
LIMIT 100
```

Byte volume by minute:

```sql
SELECT
    toStartOfMinute(received_at) AS time,
    sum(in_bytes) AS bytes
FROM flows.raw
WHERE $__timeFilter(received_at)
GROUP BY time
ORDER BY time
```

Highest-volume endpoint pairs:

```sql
SELECT
    src,
    dst,
    sum(in_bytes) AS bytes
FROM flows.raw
WHERE $__timeFilter(received_at)
GROUP BY src, dst
ORDER BY bytes DESC
LIMIT 20
```

## Development checks

```bash
shellcheck bootstrap/**/*.sh
shfmt -d .
yamllint --strict .
git diff --check
```
