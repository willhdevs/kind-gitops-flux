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
monitoring configuration, pinned to an immutable upstream commit. This
repository does not maintain custom dashboards or alert rules.

The chart installs its CRDs using Helm's standard CRD mechanism. Removing the
Helm release leaves those CRDs installed; deleting a monitoring CRD also deletes
every custom resource stored under that API.

## Development checks

```bash
shellcheck bootstrap/**/*.sh
shfmt -d .
yamllint --strict .
git diff --check
```
