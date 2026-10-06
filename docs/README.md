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
  the deid Lua hook before xnat-ingest sees the data
- [`seaweedfs.md`](components/seaweedfs.md) — S3-compatible storage for
  staged DICOM files
- [`mc.md`](components/mc.md) — MinIO client; the S3 uploader on each edge
- [`xnat-ingest.md`](components/xnat-ingest.md) — group-orthanc + assign + upload pods
- [`deidentification.md`](components/deidentification.md) — the two de-identification
  engines (Orthanc Lua hook, xnat-ingest deidentify), how to pick one and set it up (see also [choosing-a-deid-engine.md](choosing-a-deid-engine.md))

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

### Observability stack (optional — `observability.enabled` in `charts/mgmt`, installed at step 4/7 of `install.sh`)

There is no separate observability installer any more: these are pinned
subcharts of `charts/mgmt` (kube-prometheus-stack, loki, vector — see
`charts/mgmt/Chart.yaml`), applied by `./install.sh <site>` in the same step
as the rest of the management chart. It is still optional: the default is
`observability.enabled: true`, and setting it to `false` in the **management**
site's `sites/<mgmt-site>/values.yaml` omits the whole stack. Note that
`charts/edge` has a *separate* `observability.enabled` (default `false`) that
only turns on log shipping from that edge to the management cluster — so
which values file you are editing matters.

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

- [`TOUR.md`](TOUR.md) — **start here.** The guided walkthrough, read start
  to finish: what each machine is (§1), what you must decide before
  installing (§2), secrets (§3), the install itself (§4), the hop-by-hop
  path of a study (§5), `dataPolicy` — what actually deletes (§5c), and §9
  Known shortcomings, which is the evidence trail behind the removed alerts
  and the version pins. §4.1 is the only complete treatment of
  `join: bundle`, the way to bring up an edge the management node cannot
  SSH to (whitelisted-IP allowlist, VPN, GlobalProtect) — including the
  bundle's self-defence guards and the teardown caveat.
- [`hardening-decisions.md`](hardening-decisions.md) — the
  findings-and-decisions log: each item states the finding, the
  recommendation and what it costs, plus the R1-R6 revisions that amended
  earlier calls. Broader than security alone — it also covers reclaimer
  completeness, object counting, alerting correctness, retention, cluster
  adoption and sizing/immutable fields. Items marked *(measured)* were
  verified against the live cluster rather than reasoned from documentation.
- [`ca-ceremony.md`](ca-ceremony.md) — the out-of-band offline-root CA
  ceremony, required by `certManager.ca.mode: intermediate` (the chart fails
  the render and points here when that mode is set without a `secretRef`).
  Does not apply to the default `selfSigned` mode.
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
- [`clouds/`](clouds/README.md) — **per-cloud install guides**:
  [openstack-private-subnet.md](clouds/openstack-private-subnet.md)
  (recommended for production),
  [openstack-nectar.md](clouds/openstack-nectar.md) (E2E tested, but
  dev/test only), [aws.md](clouds/aws.md), [gcp.md](clouds/gcp.md),
  [azure.md](clouds/azure.md).

## How to add a new component doc

1. Copy any existing file in `components/` as a template
2. Fill in the standard sections (don't skip them — agents look for them)
3. Add a one-line entry under the appropriate section above

Keep these files **factual and current**. If something changes in the
codebase, update the doc in the same commit.
