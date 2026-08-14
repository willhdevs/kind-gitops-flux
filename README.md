# kind-gitops-flux

This repository defines a local Kubernetes environment with
[kind](https://kind.sigs.k8s.io/), Docker or Podman, and
[cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind).

## Phase 1: Local cluster bootstrap

Phase 1 creates the `kind-flux` cluster and starts the local cloud provider.
Flux, workloads, Flux manifests, and `clusters/local` are intentionally out of
scope for this phase.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docs.docker.com/engine/install/) or
  [Podman](https://podman.io/docs/installation)
- [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind/releases)

Start the container runtime before creating the cluster. Docker and Podman are
both supported.

## Create the cluster

From the repository root, run:

```bash
./bootstrap/kind/create.sh
```

The script creates the cluster from
`bootstrap/kind/kind-config.yaml`. If `kind-flux` already exists, it reuses the
existing cluster, ensures it is running, matching the runtime it was created with.
A new cluster uses Podman when available, otherwise Docker.

Verify the cluster with:

```bash
kubectl --context kind-kind-flux get nodes
```

## Run the local cloud provider

After the cluster is ready, run this in a separate terminal to support service load balancers:

```bash
./bootstrap/kind/run-cloud-provider.sh
```

## Development checks

```bash
shellcheck bootstrap/**/*.sh
shfmt -d .
yamllint --strict .
git diff --check
```
