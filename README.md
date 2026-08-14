# kind-gitops-flux

This repository is a local GitOps playground built with
[kind](https://kind.sigs.k8s.io/), Docker or Podman,
[cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind),
and [FluxCD](https://fluxcd.io/).

The target cluster is named `kind-flux`. Flux will eventually manage the
resources in `clusters/local`.

## Planned phases

1. Create the local kind cluster.
2. Bootstrap Flux using the
   [Flux GitHub bootstrap guide](https://fluxcd.io/flux/installation/bootstrap/github/).
3. Move cluster services and workloads into GitOps.
