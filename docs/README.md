# AIS Edge — Component Documentation

Per-component reference. The top-level [`README.md`](../README.md) covers the
**system as a whole** (architecture, install, network, security model). The
files in this folder are deeper dives into individual components: what each
one does, what it has access to, why we chose it, what its failure modes
are, and how to operate or replace it.

The pages are written so they can be read by engineers AND consumed by
automated agents tracking the system over time. Each follows a consistent
structure (Overview → Role → Access → How it runs → Configuration →
Operations → Risks → Replacements / Future).

## Components

### Data plane

- [`orthanc.md`](components/orthanc.md) — DICOM SCP at the edge; runs
  the Lua label hook before xnat-ingest sees the data
- [`seaweedfs.md`](components/seaweedfs.md) — S3-compatible storage for
  staged DICOM files
- [`mc.md`](components/mc.md) — MinIO client; the S3 uploader on each edge
- [`xnat-ingest.md`](components/xnat-ingest.md) — DICOM sort + upload pods

### Control plane / networking

- [`k0smotron.md`](components/k0smotron.md) — operator that hosts k0s
  control planes as pods
- [`konnectivity.md`](components/konnectivity.md) — reverse tunnel from
  edge to mgmt for kubelet RPCs
- [`haproxy.md`](components/haproxy.md) — k0smotron-haproxy DaemonSet on
  each worker (local API endpoint)
- [`nginx-ingress.md`](components/nginx-ingress.md) — single-port :443
  TLS terminator + SNI router on mgmt
- [`cert-manager.md`](components/cert-manager.md) — issues server certs
  signed by ais-edge-ca

### Observability stack (optional, install via `scripts/02d-...`)

- [`loki.md`](components/loki.md) — log store
- [`prometheus.md`](components/prometheus.md) — metrics store
- [`mimir.md`](components/mimir.md) — alternative scaled metrics store
  (future option, not deployed today)
- [`grafana.md`](components/grafana.md) — dashboards UI
- [`alertmanager.md`](components/alertmanager.md) — alert routing
- [`vector.md`](components/vector.md) — log shipper DaemonSet
- [`kube-state-metrics.md`](components/kube-state-metrics.md) — K8s
  object state metrics

### System-level references

- [`alerting-architecture.md`](alerting-architecture.md) — why pipeline-event
  alerts live in Loki ruler (LogQL) while K8s-level alerts stay in
  Prometheus, and the tradeoff against an edge-Prometheus remote-write
  topology.
- [`alerting-diy.md`](alerting-diy.md) — recipe for adding your own
  alert rules: how to discover metrics + log streams, where to put the
  rule file, copy-paste patterns for common alert shapes, how to route
  to a specific receiver, how to verify + silence during testing.
- [`dashboards.md`](dashboards.md) — every Grafana panel, its query,
  what it measures, and the s3-uploader event schema that backs the
  pipeline panels. Read this before changing any dashboard panel.
- [`cloud-deployment.md`](cloud-deployment.md) — the
  `INSTALL_TOPOLOGY=cloud` deployment shape for managed Kubernetes
  (EKS / GKE / AKS / Magnum / Nectar). Cloud LB + real DNS, the dev
  test on nip.io, and the dev-to-prod swap procedure.
- [`rsl60-existing-orthanc-deployment.md`](rsl60-existing-orthanc-deployment.md)
  — XNAT-host deployment with `rsl60` as a manual-join facility worker
  and Orthanc already running on `rsl60`.
- [`clouds/`](clouds/README.md) — **per-cloud install guides**:
  [openstack-nectar.md](clouds/openstack-nectar.md) (E2E tested),
  [aws.md](clouds/aws.md), [gcp.md](clouds/gcp.md),
  [azure.md](clouds/azure.md).

## How to add a new component doc

1. Copy any existing file in `components/` as a template
2. Fill in the standard sections (don't skip them — agents look for them)
3. Add a one-line entry under the appropriate section above

Keep these files **factual and current**. If something changes in the
codebase, update the doc in the same commit.
