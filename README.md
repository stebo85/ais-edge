# k0s + k0smotron + SeaweedFS — Edge Medical Imaging Ingest

A centrally-managed edge computing system for medical imaging data capture and upload to XNAT.
Part of [NIF FDRI Stream 2](https://github.com/Australian-Imaging-Service).

## Prerequisites

- **Management node**: Ubuntu 22.04+, 8GB+ RAM, 100GB+ disk
- **Edge worker(s)**: Ubuntu 22.04+, 4GB+ RAM, 50GB+ disk
- **SSH access**: Key-based SSH from management node to each edge worker
- **XNAT instance**: Accessible via HTTPS with a local service account
- **DICOM source**: One or more modalities that can C-STORE already-deidentified DICOMs to the edge node on port 4242 (AET=`AISEDGE`).
- **Outbound internet**: Both management and edge nodes need it (for pulling container images)

## Quick Start

### Files a site admin must edit before install

**Two** files — both have a `.template` next to them. Copy and fill in.
Both are gitignored once copied, so secrets never end up in version control.

| File (after copy) | What to set | Source |
|---|---|---|
| `config/management.env` | `MGMT_NODE_IP`, XNAT URL/user/pass, S3 admin keys, observability vars | `management.env.template` |
| `config/edge-nodes.env` | `EDGE_NODES` array — one line per edge site (IP, SSH user/key, XNAT project, scoped S3 key/secret) | `edge-nodes.env.template` |

Anything else under `config/` (`k0s-controller.yaml`, the Lua hook, `orthanc.json`) ships with sane defaults and rarely needs editing. Inside each template, look for `# REQUIRED` markers to identify the fields you must fill in.

### Steps

```bash
# 1. Clone this repo on the management node
git clone <repo-url> && cd k0s-k0smotron-mvp

# 2. Copy templates + edit the two files above
cp config/management.env.template                          config/management.env
cp config/edge-nodes.env.template                          config/edge-nodes.env
$EDITOR config/management.env \
        config/edge-nodes.env

# 3. Ensure SSH access to edge nodes
ssh-keygen -t ed25519       # if you don't have a key
ssh-copy-id ubuntu@<edge-ip>

# 4. Install
chmod +x install.sh scripts/*.sh
./install.sh
```

Architecture, data flow, security model, and component-by-component reference are all below.

---

## Deployment topology

AIS-Edge supports two deployment shapes, selected by `INSTALL_TOPOLOGY` in
`config/management.env`. Both run the same application stack — the
difference is purely how the management cluster exposes itself to edges
and how edge workers resolve management-side hostnames.

| | `INSTALL_TOPOLOGY=onprem` (default) | `INSTALL_TOPOLOGY=cloud` |
|---|---|---|
| Inbound TLS | `nginx-ingress` binds `:443` via `hostNetwork: true` on the mgmt node | `nginx-ingress` exposed as `Service type: LoadBalancer`; cloud LB owns the public IP |
| Hostname resolution | `/etc/hosts` writes on each edge VM + `hostAliases:` inside each pod | Real public DNS (a registered zone or `nip.io` for dev) |
| Where it runs | k0s on a single mgmt VM you fully control | Managed K8s (EKS, GKE, AKS, OpenStack Magnum, Nectar k0s + Octavia) |
| Cert issuer (default) | `ais-edge-ca-issuer` (self-signed root, distributed to edges) | Same `ais-edge-ca-issuer` for dev; `letsencrypt-prod` for production |

### Per-cloud install guides

Cloud-topology details differ per provider (LB controller, credential
format, FIP semantics, DNS-01 solver). Each provider has its own page
under [`docs/clouds/`](docs/clouds/README.md):

| Provider | Doc | Status |
|---|---|---|
| **OpenStack — private subnet + FIP** (recommended for production) | [`openstack-private-subnet.md`](docs/clouds/openstack-private-subnet.md) | mirrors AWS / GCP / Azure shape |
| **OpenStack — Nectar QLD shared external network** (dev/test only) | [`openstack-nectar.md`](docs/clouds/openstack-nectar.md) | ✅ E2E tested |
| AWS (EKS) | [`aws.md`](docs/clouds/aws.md) | design complete |
| GCP (GKE) | [`gcp.md`](docs/clouds/gcp.md) | design complete |
| Azure (AKS) | [`azure.md`](docs/clouds/azure.md) | design complete |

Architecture overview, packet flow, dev→prod swap procedure are in
[`docs/cloud-deployment.md`](docs/cloud-deployment.md).

### Cloud-mode config knobs

All set in `config/management.env`. Defaults + per-knob docstrings live in
[`config/management.env.template`](config/management.env.template).

```bash
export INSTALL_TOPOLOGY="cloud"
export CLOUD_PROVIDER="openstack"             # openstack | aws | gcp | azure | none
export CLOUD_CREDENTIALS_FILE="/path/to/openrc.sh"   # any shell script of `export X=Y` lines;
                                              # auto-sourced by install.sh before cloud steps
export LB_PUBLIC_IP=""                        # set if you can pre-allocate a FIP, leave blank
                                              # to let the cloud LB controller auto-assign
export LB_SUBNET_ID=""                        # OpenStack: subnet UUID where the LB VIP lives
export LB_AVAILABILITY_ZONE=""                # OpenStack: Octavia AZ (must match mgmt-VM AZ)
export PRECREATE_LB=""                        # set to "1" only on Nectar's shared-network
                                              # topology — step 00a creates the LB up front
                                              # and writes the VIP back into this file so the
                                              # rest of the install runs uninterrupted
export OCCM_CLUSTER_NAME="aisedge"            # unique per project to avoid stale-LB name
                                              # collisions in OCCM's name-based lookup
export INTERNAL_DOMAIN="aisedge.example.com"  # your DNS zone, or .<LB-IP-dashed>.nip.io for dev
export CERT_ISSUER="ais-edge-ca-issuer"       # or "letsencrypt-prod" once on a real domain
export DNS_PROVIDER=""                        # only when CERT_ISSUER=letsencrypt-*
                                              # (cloudflare | route53 | clouddns | azuredns | rfc2136)
```

### Cloud-only install step

A single extra step runs ahead of `01b` when `INSTALL_TOPOLOGY=cloud` +
`CLOUD_PROVIDER=openstack` + `PRECREATE_LB=1`:

- **`00a-precreate-lb`** — pre-creates the Octavia LB on the tenant
  subnet, captures its auto-assigned VIP, and writes
  `LB_PUBLIC_IP` + `INTERNAL_DOMAIN` back into `management.env` before
  any cert is minted. Skips silently for managed K8s (EKS / GKE / AKS /
  Magnum) where the platform CCM handles this synchronously with the
  Service creation in step 02c.

Everything else (`01`, `01b`, `02`…`07c`) is identical to the onprem
path — just with different rendering of templates (no `hostAliases:`
blocks on edge pods, no `/etc/hosts` writes on mgmt VM or edge VMs, no
IP SANs in server certs).

## Architecture

### Two-edge model

AIS-Edge has two "edge" components, both running the same ingest stack but at different points in the pipeline:

- **Facility edge** — sits on the facility's network alongside the modalities. Receives DICOMs locally (C-STORE on port 4242 or file drop), stages, and pushes over the internet to the server side.
- **Server edge** — sits on or alongside the AIS-Server / XNAT cluster. Receives staged data from the facility edge and uploads it into XNAT via REST.

Internet transfer happens **only between the two edges** — never directly from a facility to XNAT.

### Why this split

| Reason | Effect |
|---|---|
| **Centralised k8s management** | The Kubernetes management cluster runs on the server side and manages both the server-edge and facility-edge worker nodes via k0smotron + konnectivity. AIS operators `kubectl` from the server side to manage the facility edge — no per-site kubeconfig juggling |
| **Outbound-only from the facility** | The facility edge only opens outbound TCP/443 to the server side. No inbound ports needed from the internet or management network. Works behind aggressive hospital firewalls |
| **XNAT credentials stay server-side** | The XNAT REST credentials live only on the server edge. A compromised facility edge cannot reach XNAT directly |
| **Low resource floor at facility** | Facility edge runs a k0s *worker* only (the control plane is hosted on the server side via k0smotron). 4GB RAM is enough |

### Network shape

Edge nodes connect to the management cluster over a single TLS port (443).
nginx-ingress on the management host reads the SNI from the TLS handshake and
routes to the right backend. The only inbound port at the edge is DICOM
port 4242 on the local facility LAN (for modality C-STOREs); there are no
inbound ports from the internet or management network.

```
              Management Node                              Edge Worker(s)
       ┌──────────────────────────────────┐         ┌──────────────────────────┐
       │  nginx-ingress (hostNet :443)    │         │  k0s worker              │
       │  ├─ TLS terminate / SNI-route    │         │                          │
       │  │   - seaweedfs.aisedge.local   │◄────────┤  Outbound :443 to mgmt   │
       │  │   - k0s.aisedge.local         │  TLS    │                          │
       │  │   - konnect.aisedge.local     │  :443   │  Orthanc pod             │
       │  │  (all certs signed by         │         │   ├─ DICOM SCP :4242 on  │
       │  │   ais-edge-ca via cert-mgr)   │         │   │  local facility LAN  │
       │  │                               │         │   ├─ Lua hook: labels   │
       │  k0smotron operator              │         │   │  stable studies     │
       │  ├─ hosted control plane (CIP)   │         │   └─ Storage on hostPath│
       │  │   ↳ Ingress for API+konect    │         │      /data/orthanc-     │
       │  │                               │         │       storage/          │
       │  SeaweedFS (ClusterIP only)      │         │                          │
       │  ├─ S3 :8333 (HTTP, in-cluster)  │         │  xnat-ingest-sort pod    │
       │  │  edges hit via Ingress :443   │         │   ├─ REST-polls Orthanc │
       │  │                               │         │   └─ hardlinks stored   │
       │  xnat-ingest-upload pod          │         │      instances into     │
       │  └─ in-cluster DNS to seaweedfs  │         │      /data/staging/     │
       │                                  │         │                          │
       │  cert-manager: ais-edge-ca       │         │  s3-uploader pod         │
       │  ├─ self-signed root (10 yr)     │         │   ├─ mc trusts ais-edge-│
       │  └─ issues server certs (1 yr)   │         │   │  ca via ca-bundle   │
       │                                  │         │   └─ mc mirror →        │
       │                                  │         │      https://seaweedfs..│
       │                                  │         │                          │
       │                                  │         │  Credentials on edge:   │
       │                                  │         │   ├─ S3 write-only key  │
       │                                  │         │   └─ ais-edge-ca.crt    │
       │                                  │         │                          │
       │                                  │         │  Mgmt-net inbound: ZERO │
       └─────────┬────────────────────────┘         │  LAN inbound: :4242 only │
                 │ HTTPS REST API                   └──────────────────────────┘
                 ▼
       ┌──────────────────────────┐                  ◄────────  Modalities
       │  XNAT Server             │                          C-STORE to AET=
       │ (separate infrastructure)│                          AISEDGE :4242
       └──────────────────────────┘
```

## Data Flow

```
1. Modality C-STOREs to Orthanc on edge worker
   - Orthanc receives on port 4242 with AET=AISEDGE
   - DICOMs are expected to already be deidentified by the facility scanner
         │
         ▼
2. Orthanc Lua hook (on edge, deidentify-and-forward.lua)
   - Does not modify, delete, back up, or re-store DICOM instances
   - OnStableStudy (after StableAge=30s silence):
     a. PUTs label "xnat-ingest-ready" on the study
         │
         ▼
3. xnat-ingest sort (on edge, REST-pull mode)
   - Polls Orthanc REST every INGEST_LOOP_SECONDS
   - Filters: has label "xnat-ingest-ready", lacks label "xnat-ingest-skip"
   - Hardlinks instances from /data/orthanc-storage/ into
     /data/staging/PROJECT.SUBJECT.VISIT/<scan>/DICOM/
     (same filesystem — hardlink, not copy)
   - PUTs label "xnat-ingest-skip" on the study
         │
         ▼
4. s3-uploader (on edge, using `mc mirror`)
   - Reads staged sessions from /data/staging/
   - Mirrors to SeaweedFS at s3://ingest-bucket/staged/ (write-only key)
   - Deletes local /data/staging/ copy only after successful upload
   - SeaweedFS (via S3 API) handles multipart upload, checksums, resume on failure
         │
         ▼
5. SeaweedFS (on management node)
   - Stores files under s3://ingest-bucket/staged/<session>/
   - Write-only from edge, full access from management
         │
         ▼
6. xnat-ingest upload (on management node)
   - Reads from s3://ingest-bucket/staged
   - Uploads to XNAT via REST API (XNAT credentials only here)
   - Creates project/subject/session/scan hierarchy in XNAT
   - Verifies checksums after upload
   - Skips sessions already in XNAT (idempotent)
```

AIS Edge trusts the facility scanner's deidentification. Everything
downstream of Orthanc works with the identifiers already present in the
incoming DICOM.

## How the S3 Uploader Works

The `s3-uploader` pod runs on the edge worker using the `minio/mc` (MinIO Client) image.
It's a simple shell loop — no custom code:

```bash
# Configure mc with the write-only credentials.
# mc reads PEM files in /root/.mc/certs/CAs/ — we mount the ca-bundle Secret
# there, so mc trusts our ais-edge-ca-signed seaweedfs-tls cert.
mc alias set edge "https://seaweedfs.aisedge.local" "<access-key>" "<secret-key>"

# Loop forever, checking every 30 seconds
while true; do
    for session_dir in /data/staging/*/; do
        # Upload entire session directory to SeaweedFS, preserving structure
        mc mirror --overwrite "$session_dir" "edge/ingest-bucket/staged/$session_name/"

        # Delete local copy only after successful upload
        rm -rf "$session_dir"
    done
    sleep 30
done
```

`mc mirror` is like `rsync` for S3. Under the hood it:
- Breaks large files into **multipart chunks** (handles 100GB+ files)
- Uploads chunks in **parallel** for speed
- Verifies **MD5 checksums** after each chunk
- **Retries failed chunks** automatically
- Only transfers **new/changed files** if re-run (delta sync)

The actual protocol is standard HTTP PUT to the S3 API — the same protocol AWS S3 uses.
If SeaweedFS is swapped for AWS S3, the uploader works without changes (just a different endpoint URL).

## Security Model

```
Edge Worker                                   Management Node             XNAT
├─ S3 write-only key                          ├─ S3 admin key             ├─ User data
│  (write+list on one bucket only)            ├─ XNAT admin credentials   │
│  (cannot read other sites' data)            ├─ ais-edge-ca PRIVATE key  │
├─ NO XNAT credentials                        │  (in cert-manager Secret) │
├─ NO inbound ports                           │                           │
├─ ais-edge-ca PUBLIC cert (mounted)          │                           │
│  used to verify mgmt server identity        │                           │
├─ Outbound only, single port:                │                           │
│  → mgmt :443 (TLS, SNI-routed)              │                           │
```

| If compromised... | Impact |
|--------------------|--------|
| Edge worker | Attacker sees local DICOMs + scoped S3 key + public CA cert. Key can only write to ingest bucket. Cannot read other sites' data. Cannot access XNAT. Cannot forge new server certs (CA private key is on management). |
| Edge S3 key | Can write junk to one bucket. Cannot read data. Cannot access XNAT. Cannot impersonate other sites. |
| Wire (between edge and management) | Sniffer sees TLS-encrypted bytes only. Cannot read DICOMs in transit. Cannot impersonate the management server (would need a cert signed by ais-edge-ca). |
| Management node | Full access — this is your crown jewel. Harden accordingly. CA private key lives here; back it up offline if you can't tolerate re-rolling all edge trust on rebuild. |

## Repository Structure

```
k0s-k0smotron-mvp/
├── README.md                              ← You are here
├── install.sh                             ← Main installer (run this)
├── ais-edge-ca.crt                        ← Public CA cert (gitignored; generated at install)
├── config/
│   ├── management.env.template            ← Management node config (copy to management.env)
│   ├── edge-nodes.env.template            ← Edge nodes config (copy to edge-nodes.env)
│   ├── k0s-controller.yaml               ← k0s cluster config
│   └── orthanc/                           ← Edge-side Orthanc config (mounted as ConfigMaps)
│       ├── orthanc.json                   ← Daemon config (AET, ports, storage paths)
│       └── deidentify-and-forward.lua     ← Label-only Lua hook
├── manifests/
│   ├── 01-management/                     ← Runs on management cluster
│   │   ├── cert-issuers.yaml              ← cert-manager bootstrap + CA + CA Issuer
│   │   ├── nginx-ingress-values.yaml.tpl  ← helm values for nginx-ingress
│   │   ├── seaweedfs.yaml.tpl             ← SeaweedFS Deployment + ClusterIP Service
│   │   ├── seaweedfs-tls-cert.yaml.tpl    ← server cert for SeaweedFS Ingress
│   │   ├── seaweedfs-ingress.yaml.tpl     ← nginx Ingress at :443 with SNI route
│   │   ├── edge-cluster.yaml.tpl          ← Hosted k0s control plane (with spec.ingress)
│   │   └── xnat-upload.yaml.tpl           ← Reads SeaweedFS → uploads to XNAT
│   └── 02-edge/                           ← Runs on edge workers (child cluster)
│       ├── xnat-ingest.yaml.tpl           ← Sort (Orthanc REST-pull mode) + s3-uploader
│       └── orthanc.yaml.tpl               ← Orthanc Deployment + Service + Secret
├── scripts/
│   ├── 00-common.sh                       ← Shared functions
│   ├── 01-install-k0s.sh                  ← Install k0s on mgmt
│   ├── 02-install-k0smotron.sh            ← cert-manager + k0smotron
│   ├── 02b-bootstrap-ca.sh                ← Bootstrap self-signed CA (ais-edge-ca)
│   ├── 02c-install-nginx-ingress.sh       ← nginx-ingress on hostNetwork :443
│   ├── 02d-install-observability.sh       ← Loki + Prom + Grafana + Vector (optional)
│   ├── 03-deploy-seaweedfs.sh             ← SeaweedFS + TLS cert + Ingress
│   ├── 04-deploy-xnat-upload.sh           ← Mgmt-side XNAT upload pod
│   ├── 05-setup-edge-cluster.sh           ← Per-edge: hosted control plane + token
│   ├── 06-join-edge-worker.sh             ← Per-edge: install k0s worker, /etc/hosts, CoreDNS
│   ├── 07-deploy-edge-ingest.sh           ← Per-edge: deploy sort (REST-pull) + s3-uploader
│   ├── 07b-deploy-edge-observability.sh   ← Per-edge: Vector log shipper (optional)
│   ├── 07c-deploy-edge-orthanc.sh         ← Per-edge: deploy Orthanc + label Lua hook
│   ├── rotate-ca.sh                       ← CA rotation (--phase=1 / --phase=2)
│   └── uninstall.sh                       ← Tears down everything
└── .gitignore
```

`.tpl` files are manifest templates — placeholders like `{{CLUSTER_NAME}}` are replaced with
values from your config files during installation.

## Installing on an Existing Kubernetes Cluster

If you already have a Kubernetes cluster running (k3s, kubeadm, MicroK8s, etc.):

1. Set `INSTALL_MODE="existing"` in `config/management.env`
2. Ensure `kubectl` is configured and pointing to your cluster (`~/.kube/config`)
3. Ensure a default StorageClass exists (check with `kubectl get sc`)
4. Run `./install.sh` — it will skip k0s installation and use your existing cluster

The installer will deploy k0smotron, SeaweedFS, and the upload pod as regular workloads
on your existing cluster. Everything else works the same.

## Adding More Edge Nodes

Edit `config/edge-nodes.env` and add entries to the `EDGE_NODES` array:

```bash
EDGE_NODES=(
  "edge-uqcai|203.101.230.171|ubuntu|~/.ssh/id_ed25519|uqcai-project|edge-uqcai-key|uqcai-secret"
  "edge-usyd|10.0.1.50|ubuntu|~/.ssh/id_ed25519|usyd-project|edge-usyd-key|usyd-secret"
  "edge-newcastle|10.0.2.50|ubuntu|~/.ssh/id_ed25519|newcastle-project|edge-newcastle-key|newcastle-secret"
)
```

Each edge node gets:
- Its own hosted k0s control plane (separate namespace on management cluster)
- Its own scoped S3 credentials (write+list to ingest bucket only — isolated per site)
- Its own kubeconfig file (`kubeconfig-edge-uqcai`, etc.)
- Its own xnat-ingest pods

Then re-run `./install.sh` — it will skip already-installed components and only set up new nodes.

## Removing a Single Edge Node

To remove one edge site without affecting others:

```bash
# 1. Delete workloads on the edge cluster
kubectl --kubeconfig kubeconfig-edge-uqcai delete namespace xnat-ingest

# 2. Reset the edge worker VM
ssh ubuntu@<edge-ip> "sudo k0s stop && sudo k0s reset"

# 3. Delete the hosted cluster from management
kubectl delete namespace edge-uqcai

# 4. Remove the S3 identity (regenerate s3.json without this edge user)
#    Just remove the entry from edge-nodes.env, then re-run scripts/03-deploy-seaweedfs.sh
#    (it regenerates the SeaweedFS s3.json ConfigMap and rolls the pod)

# 5. Clean up generated files
rm kubeconfig-edge-uqcai join-token-edge-uqcai

# 6. Remove the entry from config/edge-nodes.env
```

## Tested Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Ubuntu | 22.04.5 LTS | Management and edge nodes |
| k0s | v1.35.2+k0s.0 | Both management cluster and edge workers |
| k0smotron | v1.10.4 (stable) | Installed via `kubectl apply` (not Helm). Uses built-in `spec.ingress` for SNI routing. |
| cert-manager | latest | Issues `ais-edge-ca` (10y root) + per-service server certs (1y, auto-renew) |
| nginx-ingress | latest (helm) | hostNetwork :443. SSL passthrough enabled (k0s API + konnectivity); TLS termination for SeaweedFS. |
| SeaweedFS | 3.99 | `chrislusf/seaweedfs:3.99` (last 3.x stable, avoids 4.18/4.19 filer memory regression — issue #9035). ClusterIP only; external access via Ingress. |
| MinIO Client (mc) | latest | `minio/mc:latest` — vendor-neutral S3 client used by edge s3-uploader. Trusts `ais-edge-ca` via mounted ca-bundle Secret. |
| Orthanc | 1.12.6 (plugins) | `jodogne/orthanc-plugins:1.12.6` — DICOM SCP on edge port 4242. Needs ≥ 1.12.0 for study-level labels. |
| xnat-ingest | v0.1.0 | `ghcr.io/aswinnarayanan/xnat-ingest:v0.1.0` — logging-v3 + Orthanc REST-pull mode. |
| local-path-provisioner | v0.0.30 | Default StorageClass for etcd PVCs |

To pin specific versions in production, replace `:latest` / `:3.99` tags in the `.tpl`
manifests with explicit versions (e.g. `chrislusf/seaweedfs:3.99-rc1`).

## How the Template System Works

Manifest files ending in `.tpl` contain placeholders like `{{S3_BUCKET}}`.
The `render()` function in `scripts/00-common.sh` performs simple string replacement
at install time — no Helm, no Jinja, no external tools required.

```bash
# Example: what happens when install.sh processes seaweedfs-ingress.yaml.tpl
Input:   host: {{SEAWEEDFS_HOSTNAME}}
Output:  host: seaweedfs.aisedge.local
```

Values come from `config/management.env` and `config/edge-nodes.env`. You never edit `.tpl` files.

## S3 Path Structure in SeaweedFS

```
s3://ingest-bucket/
└── staged/
    ├── test-project.patient01.visit01/           ← one directory per session
    │   └── 1.T1w_MPRAGE/                        ← scan ID + description
    │       └── DICOM/                            ← resource type
    │           ├── file1.dcm
    │           ├── file2.dcm
    │           └── MANIFEST.json
    ├── test-project.patient02.visit01/
    │   └── ...
    └── ...
```

The `staged/` prefix separates ingest data from any other bucket contents.
Session directory names follow the format `PROJECT.SUBJECT.VISIT`.

## Edge Data Directory Structure

On each edge worker:

```
/data/xnat-ingest/
├── orthanc-storage/     ← Orthanc DICOM storage tree
└── staging/
    └── PROJECT.SUBJECT.VISIT/  ← xnat-ingest sort's hardlinked output, awaiting S3 upload
```

Files flow: Modality C-STORE → Orthanc stores the received DICOM → Lua labels stable study → sort hardlinks → `staging/` → SeaweedFS → eventually deleted from edge after successful S3 upload.

`/data/orthanc-storage` and `/data/xnat-ingest/staging` **must be on the same physical filesystem** so hardlinks resolve (cross-fs hardlinks fail with EXDEV).

## Health Checks

```bash
# Management cluster health
kubectl get pods -A                              # all pods should be Running
kubectl get nodes                                # management node should be Ready

# Edge cluster health
kubectl --kubeconfig kubeconfig-<name> get nodes  # edge worker should be Ready
kubectl --kubeconfig kubeconfig-<name> get pods -n xnat-ingest  # sort + s3-uploader Running

# SeaweedFS health (TLS via nginx-ingress; CA bundle is ais-edge-ca.crt)
curl --cacert ais-edge-ca.crt \
     --resolve seaweedfs.aisedge.local:443:<MGMT_IP> \
     https://seaweedfs.aisedge.local/   # → 403 (S3 unauth) means path works

# SeaweedFS master + filer (admin only — port-forward, no external port)
kubectl port-forward -n seaweedfs svc/seaweedfs 9333:9333 &  # master  http://localhost:9333
kubectl port-forward -n seaweedfs svc/seaweedfs 8888:8888 &  # filer   http://localhost:8888

# SeaweedFS from edge (with CA verification)
ssh ubuntu@<EDGE_IP> "curl --cacert /tmp/ais-edge-ca.crt https://seaweedfs.aisedge.local/"

# SeaweedFS bucket contents (mgmt-side via port-forward + mc alias)
kubectl port-forward -n seaweedfs svc/seaweedfs 8333:8333 &
mc alias set seaweed-admin http://localhost:8333 <admin-key> <admin-secret>
mc ls seaweed-admin/ingest-bucket/staged/        # list sessions in bucket

# XNAT connectivity
curl -sk <XNAT_URL>                              # should return HTML

# Check logs for errors
kubectl logs -n xnat-upload -l component=upload --tail=5           # XNAT upload
kubectl --kubeconfig kubeconfig-<name> logs -n xnat-ingest -l component=sort --tail=5
kubectl --kubeconfig kubeconfig-<name> logs -n xnat-ingest -l component=s3-uploader --tail=5
```

## SeaweedFS Master & Filer UIs

The SeaweedFS Service is **ClusterIP only** — no external port. Reach
the admin UIs via `kubectl port-forward` from the management node:

```bash
# Master UI — cluster topology, volume servers, free capacity, leader election
kubectl port-forward -n seaweedfs svc/seaweedfs 9333:9333 &
xdg-open http://localhost:9333

# Filer UI — browse the filesystem layer (objects under /buckets/<bucket>/...)
kubectl port-forward -n seaweedfs svc/seaweedfs 8888:8888 &
xdg-open http://localhost:8888
```

For an S3-style admin experience, port-forward 8333 and use `mc`:

```bash
kubectl port-forward -n seaweedfs svc/seaweedfs 8333:8333 &
mc alias set seaweed-admin http://localhost:8333 <admin-key> <admin-secret>
mc ls seaweed-admin/                                    # list buckets
mc ls --recursive seaweed-admin/ingest-bucket/staged/   # list sessions
mc admin info seaweed-admin                             # cluster info
```

## Updating Components

**Update xnat-ingest image:**
```bash
# Edge cluster — restart pods to pull latest image
kubectl --kubeconfig kubeconfig-<name> rollout restart deployment/xnat-ingest-sort -n xnat-ingest
kubectl --kubeconfig kubeconfig-<name> rollout restart deployment/s3-uploader -n xnat-ingest

# Management cluster — restart XNAT upload pod
kubectl rollout restart deployment/xnat-ingest-upload -n xnat-upload
```

**Update SeaweedFS:**
```bash
kubectl rollout restart deployment/seaweedfs -n seaweedfs
```

**Update k0s on edge workers:**
k0s supports in-place upgrades via Autopilot. For manual upgrade:
```bash
ssh ubuntu@<EDGE_IP>
sudo k0s stop
curl -sSLf https://get.k0s.sh | sudo sh    # installs latest
sudo k0s start
```

**Update k0smotron:**
```bash
kubectl apply --server-side=true -f https://docs.k0smotron.io/stable/install.yaml
```

## Backup and Restore

**What to back up:**
- `config/management.env` and `config/edge-nodes.env` — your configuration
- SeaweedFS data (`/data/seaweedfs/` on management node) — staged files in transit
- XNAT — your actual data destination (backed up separately)

**What does NOT need backup:**
- Edge worker data (`/data/xnat-ingest/`) — transient staging area
- k0s/k0smotron state — can be rebuilt from this repo
- Generated files (`kubeconfig-*`, `join-token-*`) — regenerated on install

**Restoring from scratch:**
1. Provision fresh VMs
2. Clone this repo, copy your saved config files
3. Run `./install.sh`

## Known Limitations

- **Self-signed CA (no public trust chain)** — `ais-edge-ca` is local to this deployment.
  Anything that doesn't load the CA bundle (browsers, third-party tools) will see
  certificate-untrusted warnings. For a publicly-trusted chain, plug in a real CA (e.g.
  Let's Encrypt via cert-manager's HTTP-01 / DNS-01 ACME issuer).
- **mTLS not implemented** — edges authenticate to SeaweedFS via S3 access keys, not
  client certificates. The wire is encrypted; identity is via key. Add a mutual-TLS
  layer for stronger edge identity.
- **No monitoring/alerting** — SeaweedFS disk usage, pod health, and upload failures
  are not automatically monitored. Add Prometheus + Grafana for production
  (SeaweedFS exposes Prometheus metrics on the master and filer).
- **Single management node** — no HA for k0smotron, nginx-ingress, or SeaweedFS.
  For production, split SeaweedFS into separate master/volume/filer/s3 deployments
  with 3 masters, run multiple ingress replicas (drop hostNetwork, use a real load
  balancer or VRRP), and run a multi-replica k0smotron control plane per cluster;
  see "Scaling SeaweedFS" below.
- **DICOM files with missing AccessionNumber** go to `__invalid__/` — requires manual
  rename. This is an xnat-ingest limitation, not a system issue. Real clinical DICOMs
  will have this field populated.
- **emptyDir persistence for hosted control planes** — etcd data is lost if the
  management node restarts. For production, use a proper StorageClass with persistent volumes.
- **No automatic cleanup of SeaweedFS** — successfully uploaded sessions remain in
  SeaweedFS until manually deleted. Add an S3 lifecycle rule or a cleanup job for
  production.
- **First-time install needs internet on the edge VM.** The edge worker pulls the
  k0s binary from `get.k0s.sh` and container images from `quay.io`, `docker.io`, and
  `ghcr.io` (k0s, konnectivity-agent, haproxy, xnat-ingest, minio/mc). Once installed,
  the edge needs only the single 443 connection back to management — no further
  registry access. For air-gapped sites, pre-stage the k0s binary at
  `/usr/local/bin/k0s` and drop a `k0s airgap`-style image bundle into
  `/var/lib/k0s/images/` on the edge VM before running the installer (k0s auto-imports
  on start). A "build airgap bundle" helper script is not yet included.
- **Konnectivity is HTTP/2 + gRPC over TLS.** Stateful firewalls or IDS appliances
  that aggressively normalise TLS or block long-lived HTTP/2 streams can disrupt the
  reverse tunnel — see the "Konnectivity and middleboxes" section below before
  enabling the deployment behind a deep-inspection proxy.

## Scaling SeaweedFS

The single-pod all-in-one deployment is for the MVP. For production scale-out, split
the SeaweedFS components into separate Deployments/StatefulSets:

| Component | What it does | HA recommendation |
|---|---|---|
| Master | Cluster metadata, leader election | 3 replicas (Raft consensus) |
| Volume server | Stores chunked data | N replicas across nodes; each backed by its own disk |
| Filer | Filesystem layer (required for S3) | 2+ replicas; backed by an external metadata store (Redis/ScyllaDB/Postgres) |
| S3 gateway | S3 API endpoint | 2+ replicas behind a Service / load balancer |

Edge clients (`mc mirror`) don't change — they still talk to the S3 endpoint. The
internal architecture changes; the external API does not.

## XNAT Configuration

Before ingesting data, ensure:

1. **XNAT project exists** — create it in the XNAT web UI before uploading.
   The project ID must match `PROJECT_ID` in `config/edge-nodes.env`.
2. **XNAT user is a local account** — not AAF/OIDC. Create via Administer → Users.
3. **XNAT user has project permissions** — at least Member or Collaborator on the target project.

xnat-ingest authenticates via `POST /data/JSESSION` with username/password and uses the
session token for all subsequent REST API calls.

## Accessing Clusters

```bash
# Management cluster
kubectl get pods -A

# Specific edge cluster
kubectl --kubeconfig kubeconfig-edge-uqcai get pods -n xnat-ingest
kubectl --kubeconfig kubeconfig-edge-usyd get nodes

# Logs
kubectl --kubeconfig kubeconfig-edge-uqcai logs -n xnat-ingest -l component=sort -f
kubectl --kubeconfig kubeconfig-edge-uqcai logs -n xnat-ingest -l component=s3-uploader -f
kubectl logs -n xnat-upload -l component=upload -f   # management upload to XNAT

# SeaweedFS admin UIs (ClusterIP only — port-forward from mgmt)
kubectl port-forward -n seaweedfs svc/seaweedfs 9333:9333 &  # master
kubectl port-forward -n seaweedfs svc/seaweedfs 8888:8888 &  # filer
```

## Testing

```bash
# C-STORE an already-deidentified DICOM to Orthanc at the edge.
storescu -aec AISEDGE -aet TEST_MOD <EDGE_IP> 4242 test.dcm

# Watch the Orthanc Lua label events
kubectl --kubeconfig kubeconfig-edge-dev logs -n xnat-ingest deploy/orthanc -f \
  | grep -E 'instance_received|study_labeled_ready|ERROR'

# Watch sort pod REST-pull from Orthanc and hardlink into staging
kubectl --kubeconfig kubeconfig-edge-dev logs -n xnat-ingest -l component=sort -f

# Watch s3-uploader push to SeaweedFS
kubectl --kubeconfig kubeconfig-edge-dev logs -n xnat-ingest -l component=s3-uploader -f

# Watch upload to XNAT
kubectl logs -n xnat-upload -l component=upload -f
```

## Failure Scenarios

| Scenario | What happens | Recovery |
|----------|-------------|---------|
| Network drops mid-upload | SeaweedFS S3 multipart — completed chunks saved | mc retries on next loop cycle |
| Edge VM crashes | Files safe in /data/staging/ | k0s auto-starts, pods resume |
| SeaweedFS crashes | Edge uploads fail, files safe on edge | Pod auto-restarts, edge retries |
| Management node crashes | Edge files accumulate locally | Management restarts, edge reconnects |
| XNAT is down | SeaweedFS fills up | XNAT returns, upload pod clears backlog |
| SeaweedFS disk full | Edge uploads fail, files safe on edge | Expand `/data/seaweedfs/` or clear XNAT backlog |

## Architecture: Deeper Dive

The overview above shows the major components and the single 443 outbound path.
This section drills into the host-level state, every namespace, the trust
relationships between certificates, and how in-cluster Service traffic actually
reaches the API server. Useful when debugging or reviewing the design.

```
══════════════════════════════════════════════════════════════════════════════════════
  EDGE VM   (203.101.230.171)        ZERO inbound • outbound only TCP :443
══════════════════════════════════════════════════════════════════════════════════════

  Host state
    /etc/hosts            203.101.224.240  seaweedfs.aisedge.local
                                           k0s.aisedge.local
                                           konnect.aisedge.local      (added by 06)
    /etc/haproxy/certs/
        server.pem        cert+key, signed by the cluster's internal k0s CA
                          (so workload pods trust haproxy via the projected
                           serviceaccount ca.crt — without this every pod that
                           hits the kubernetes Service gets "unknown authority")
        ca.crt            the same cluster CA — haproxy uses it to verify the
                          upstream API
    k0sworker.service     systemd unit; kubelet talks to https://k0s.aisedge.local:443
                          (URL rewritten inside the join-token by 05-setup-edge..)

  ┌─ default ns ──────────────────────────────────────────────────────────────────┐
  │   k0smotron-haproxy   DaemonSet, hostNetwork:true                             │
  │     frontend  bind [::]:7443 ssl crt /etc/haproxy/certs/server.pem            │
  │     backend   k0s.aisedge.local:443 ssl verify required sni=k0s.aisedge.local │
  │   * EndpointSlice for the kubernetes Service points at <edge-IP>:7443         │
  │     so any pod calling 10.96.0.1:443 → kube-proxy NAT → local haproxy → mgmt  │
  └───────────────────────────────────────────────────────────────────────────────┘
  ┌─ kube-system ns ──────────────────────────────────────────────────────────────┐
  │   coredns          Corefile has  hosts { … aisedge.local … fallthrough }      │
  │   konnectivity-agent  --proxy-server-host=konnect.aisedge.local --port=443    │
  │   kube-proxy / kube-router / metrics-server                                   │
  └───────────────────────────────────────────────────────────────────────────────┘
  ┌─ xnat-ingest ns ──────────────────────────────────────────────────────────────┐
  │   orthanc            DICOM SCP :4242 (hostPort), Lua label hook,              │
  │                      storage at /data/orthanc-storage                         │
  │     mounts    ConfigMaps orthanc-config/-scripts                              │
  │   xnat-ingest-sort   loop 60s, REST-pull from orthanc.xnat-ingest.svc:8042    │
  │                      hardlinks /data/orthanc-storage → /data/staging          │
  │   s3-uploader        loop 30s, runs:  mc mirror /data/staging  edge/bucket    │
  │     env       S3_ENDPOINT=https://seaweedfs.aisedge.local                     │
  │     mount     Secret ca-bundle (= ais-edge-ca.crt) → /root/.mc/certs/CAs/     │
  │     hostAliases   3 aisedge.local names → MGMT_NODE_IP                        │
  │   hostPath    /data/xnat-ingest/{orthanc-storage,staging}                     │
  │   Secret      s3-edge-credentials   (write+list scoped to ingest-bucket)      │
  └───────────────────────────────────────────────────────────────────────────────┘

                              │
                              │   ALL outbound traffic: TCP 443 (TLS, SNI-routed)
                              │   firewall rule: ALLOW edge → MGMT_IP dst-port 443
                              ▼

══════════════════════════════════════════════════════════════════════════════════════
  MGMT NODE  (203.101.224.240)        k0s controller+worker (single-node)
══════════════════════════════════════════════════════════════════════════════════════

  Host state
    /etc/hosts            same 3 aisedge.local entries (added by 05-setup-edge..)
    *:443                 owned by ingress-nginx-controller pod (hostNetwork:true)

  ┌─ ingress-nginx ns ────────────────────────────────────────────────────────────┐
  │   ingress-nginx-controller   helm-managed; --enable-ssl-passthrough           │
  │     proxy-body-size=50g  proxy-read-timeout=3600  proxy-send-timeout=3600     │
  │   ┌─ SNI router  (port 443) ─────────────────────────────────────────────┐    │
  │   │  seaweedfs.aisedge.local → svc/seaweedfs:8333    (TLS terminate)     │    │
  │   │  k0s.aisedge.local       → kmc-edge-dev-nodeport:30443 (passthrough) │    │
  │   │  konnect.aisedge.local   → kmc-edge-dev-nodeport:30132 (passthrough) │    │
  │   └──────────────────────────────────────────────────────────────────────┘    │
  └───────────────────────────────────────────────────────────────────────────────┘
  ┌─ cert-manager ns ─────────────────────────────────────────────────────────────┐
  │   ClusterIssuer  selfsigned-bootstrap                                         │
  │   Certificate    ais-edge-ca       isCA, RSA 4096, 10 yr                      │
  │   ClusterIssuer  ais-edge-ca-issuer  ─── signs server certs ───►              │
  │     • seaweedfs-tls   1 yr, auto-renew -30d, SANs = seaweedfs..local +MGMT_IP │
  │   Export         ais-edge-ca.crt → REPO_DIR  (distributed to edges as Secret) │
  └───────────────────────────────────────────────────────────────────────────────┘
  ┌─ k0smotron ns + edge-dev ns (per-edge cluster) ───────────────────────────────┐
  │   k0smotron-controller-manager   operator                                     │
  │   kmc-edge-dev-0          k0s API server pod                                  │
  │     spec.k0sConfig.spec.api.sans = [k0s.aisedge.local, konnect.., MGMT_IP]    │
  │     cert issued by k0smotron-managed cluster CA (Secret edge-dev-ca)          │
  │   kmc-edge-dev-etcd-0     etcd                                                │
  │   svc/kmc-edge-dev-nodeport   NodePort 30443/30132 (in-cluster bridge only)   │
  │   Ingress kmc-edge-dev    auto-created from spec.ingress on the Cluster CR    │
  │     ssl-passthrough on hosts k0s.aisedge.local + konnect.aisedge.local        │
  └───────────────────────────────────────────────────────────────────────────────┘
  ┌─ seaweedfs ns ────────────────────────────────────────────────────────────────┐
  │   seaweedfs   Deployment, all-in-one (master+volume+filer+s3) chrislusf:3.99  │
  │   svc/seaweedfs   ClusterIP only — no external port (admin via port-forward)  │
  │   ConfigMap s3-config   admin + per-edge IAM identities (config-hash rolls)   │
  │   hostPath  /data/seaweedfs   Haystack volumes + filer leveldb                │
  └───────────────────────────────────────────────────────────────────────────────┘
  ┌─ xnat-upload ns ──────────────────────────────────────────────────────────────┐
  │   xnat-ingest-upload   polls s3://ingest-bucket/staged/, pushes to XNAT       │
  │     env   S3_ENDPOINT=http://seaweedfs.seaweedfs.svc.cluster.local:8333       │
  │              (in-cluster path — never leaves the management node)             │
  │   Secrets   xnat-credentials, s3-credentials                                  │
  └───────────────────────────────────────────────────────────────────────────────┘

                              │   HTTPS to XNAT's public-CA-signed endpoint
                              ▼

  ┌────────────────────────────────────────────────────────────────────────────────┐
  │  XNAT SERVER   (xnat-test.ssdsorg.cloud.edu.au — separate k3s cluster)         │
  │  Receives sessions via REST API; out of scope for this repo                    │
  └────────────────────────────────────────────────────────────────────────────────┘
```

### Trust chains (who signs what)

```
  ais-edge-ca (10 yr root)  ──signs──►  seaweedfs-tls   (presented by nginx)
                                            ▲
                                            └─ trusted by edge mc via mounted
                                               ca-bundle Secret (= ais-edge-ca.crt)

  k0smotron cluster CA      ──signs──►  k0s API server cert (kmc-edge-dev-0)
   (Secret edge-dev-ca)                     ▲
                                            └─ trusted by edge kubelet via the
                                               CA embedded in the join-token

  cluster CA (same as above)──signs──►  /etc/haproxy/certs/server.pem
                                            ▲
                                            └─ trusted by every workload pod via
                                               its projected serviceaccount ca.crt
```

### In-cluster Service traffic on the worker

```
   pod (in child cluster)
        │   GET kubernetes.default.svc.cluster.local
        │   → resolves to ClusterIP 10.96.0.1:443
        ▼
   kube-proxy iptables NAT
        │   destination rewritten to <edge-IP>:7443 (per EndpointSlice)
        ▼
   k0smotron-haproxy DS pod   (hostNetwork on the same worker)
        │   TLS terminate using server.pem (signed by cluster CA → pod trusts it)
        │   open NEW outbound TLS conn:
        ▼
   nginx-ingress on MGMT_IP:443 (SNI = k0s.aisedge.local → ssl-passthrough)
        │
        ▼
   kmc-edge-dev-nodeport:30443 → kmc-edge-dev-0 (k0s API)
```

## FAQ

**Q: Can I run k0smotron on my existing k3s/kubeadm cluster?**
Yes. Set `INSTALL_MODE="existing"` in `config/management.env`. k0smotron is just a Kubernetes
operator — it runs on any conformant cluster with cert manager. Edge workers still use k0s.

**Q: Does k0s run on Windows?**
Not natively. Options: WSL2, Hyper-V VM, or Docker Desktop.

**Q: What credentials are stored on the edge?**
Only a scoped SeaweedFS S3 key. It can only PUT/LIST on one bucket. It cannot read other
sites' data, access XNAT, or do anything else. XNAT credentials never leave the management node.

**Q: How does the edge communicate without inbound ports?**
All connections are outbound from the edge to the management node on a single port:
- TLS port 443 — multiplexed by SNI:
  - `k0s.aisedge.local` → k0s API server (kubelet → API)
  - `konnect.aisedge.local` → konnectivity tunnel (API → kubelet via reverse tunnel)
  - `seaweedfs.aisedge.local` → SeaweedFS S3 (mc mirror data uploads)
The management node sends commands back through the konnectivity tunnel (edge-initiated).

**Q: What is konnectivity?**
A reverse tunnel built into Kubernetes. The edge opens an outbound connection to the
management node and keeps it open. kubectl commands flow back through this same connection.
No inbound ports needed on the edge.

**Q: What happens if the SeaweedFS edge key is stolen?**
An attacker can only write junk files to the ingest bucket. They cannot read other sites'
data, cannot access XNAT, and cannot access patient information. The key is easily rotated.

**Q: How do I rotate the SeaweedFS edge credentials?**
1. Generate new credentials in `config/edge-nodes.env` for that edge entry.
2. Re-run `scripts/03-deploy-seaweedfs.sh` — it regenerates `s3.json` from env and
   rolls the SeaweedFS pod via the config-hash annotation. Old credentials become invalid.
3. Re-run `scripts/07-deploy-edge-ingest.sh <entry>` for the affected edge — the K8s
   Secret on the edge cluster is updated and the s3-uploader pod restarts.

**Q: What is a "child cluster" vs "management cluster"?**
The management cluster runs k0smotron and hosts control planes for edge sites.
Each edge site has a "child cluster" — its own Kubernetes cluster whose control plane
runs as pods on the management node, but whose workers are at the edge site.
They have separate kubeconfigs, namespaces, and RBAC.

**Q: Can one edge site have multiple workers?**
Yes. Give multiple machines the same join token and they all join the same child cluster.
Pin specific pods to specific workers using `nodeSelector` in the manifest.

## Troubleshooting

**k0s worker not joining:**
- Check token: `sudo cat /etc/k0s/join-token | head -c 50` (should not be empty)
- Verify the embedded URL: `cat /etc/k0s/join-token | base64 -d | gunzip | grep server`
  (should show `https://k0s.aisedge.local:443`)
- Check `/etc/hosts` has the aisedge.local entries: `grep aisedge /etc/hosts`
- Check connectivity: `curl --cacert /tmp/ais-edge-ca.crt https://k0s.aisedge.local/version`
  (TLS error = cert/CA mismatch; refused = nginx-ingress / network)
- Check logs: `sudo journalctl -u k0sworker --no-pager -n 30`
- Note: `k0s status` does NOT work on workers. Use `systemctl is-active k0sworker`.

**konnectivity-agent in CrashLoop / "lookup konnect.aisedge.local: no such host":**
- The child cluster's CoreDNS does not have the aisedge.local hosts entry.
  Re-run `06-join-edge-worker.sh` (idempotent) or apply the Corefile manually.
- Verify: `KUBECONFIG=kubeconfig-<edge> kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}' | grep aisedge`

**s3-uploader: "x509: certificate signed by unknown authority":**
- The `ca-bundle` Secret is missing or empty on the edge cluster. Re-run
  `07-deploy-edge-ingest.sh <edge-entry>` — it pushes `ais-edge-ca.crt` to the
  edge cluster's `xnat-ingest/ca-bundle` Secret and rolls the s3-uploader.
- Verify: `KUBECONFIG=kubeconfig-<edge> kubectl get secret -n xnat-ingest ca-bundle -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -subject`

**Pods stuck in Pending:**
- Check events: `kubectl describe pod <name> -n <namespace>`
- Common cause: no StorageClass (management cluster needs local-path-provisioner)
- Edge pods use hostPath, not PVC — check directory exists on worker

**xnat-ingest sort puts files in __invalid__:**
- The DICOM file is missing required metadata (usually AccessionNumber)
- This is normal for sample files. Rename and move manually for testing.
- With real clinical DICOMs, this won't happen.

**Upload pod can't reach SeaweedFS:**
- The mgmt upload pod uses in-cluster DNS — TLS/Ingress not involved.
  Test: `kubectl exec -n xnat-upload deploy/xnat-ingest-upload -- curl -s http://seaweedfs.seaweedfs.svc.cluster.local:8333/`
- Check SeaweedFS pod: `kubectl logs -n seaweedfs -l app=seaweedfs`

**Upload pod can't reach XNAT:**
- Test: `curl -sk <XNAT_URL>`
- Check XNAT credentials in management cluster secret
- XNAT project must exist before upload (create in XNAT web UI)

**Server cert about to expire (or compromised CA):**
- Server certs auto-renew via cert-manager (1-year duration, 30-day renewBefore).
- Force renewal: `kubectl delete secret seaweedfs-tls -n seaweedfs` and cert-manager
  re-issues from the CA Issuer.
- Full CA rotation: `scripts/rotate-ca.sh --phase=1` then (after 14-30 days) `--phase=2`.

## Using AWS S3 Instead of SeaweedFS

This setup uses self-hosted SeaweedFS by default, but you can swap it for AWS S3 (or any
S3-compatible service like Google Cloud Storage, Backblaze B2, MinIO, Garage, Ceph RGW)
with minimal changes — `mc` and `boto3` speak vanilla S3.

### What Changes

| Component | SeaweedFS (default) | AWS S3 |
|-----------|--------------------|--------|
| Storage server | SeaweedFS pod on management node | AWS managed service |
| Management manifests | `manifests/01-management/seaweedfs.yaml.tpl` deployed | **Not deployed** — skip step 03 |
| Upload pod S3 endpoint | `http://seaweedfs.seaweedfs.svc.cluster.local:8333` | `https://s3.amazonaws.com` (default) |
| Edge S3 endpoint | `https://seaweedfs.aisedge.local` (TLS, ais-edge-ca) | `https://s3.<region>.amazonaws.com` (TLS, public CA) |
| Credentials | SeaweedFS s3.json identities | AWS IAM access keys |

### Step-by-Step

**1. Create AWS resources:**
```bash
# Create an S3 bucket
aws s3 mb s3://my-ingest-bucket --region ap-southeast-2

# Create an IAM user for the edge (write-only)
aws iam create-user --user-name edge-writer
aws iam put-user-policy --user-name edge-writer --policy-name write-only --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["s3:PutObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::my-ingest-bucket/*"},
    {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":"arn:aws:s3:::my-ingest-bucket"}
  ]
}'
aws iam create-access-key --user-name edge-writer
# → note the AccessKeyId and SecretAccessKey

# Create an IAM user for the management upload pod (read + delete)
aws iam create-user --user-name mgmt-reader
aws iam put-user-policy --user-name mgmt-reader --policy-name read-delete --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["s3:GetObject","s3:DeleteObject","s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::my-ingest-bucket","arn:aws:s3:::my-ingest-bucket/*"]}
  ]
}'
aws iam create-access-key --user-name mgmt-reader
```

**2. Update config files:**

`config/management.env`:
```bash
export S3_BUCKET="my-ingest-bucket"
# These become the management upload pod's AWS credentials:
export S3_ADMIN_ACCESS_KEY="<mgmt-reader-access-key>"
export S3_ADMIN_SECRET_KEY="<mgmt-reader-secret-key>"
```

`config/edge-nodes.env`:
```bash
EDGE_NODES=(
  "edge-uqcai|203.101.230.171|ubuntu|~/.ssh/id_ed25519|uqcai-project|<edge-writer-access-key>|<edge-writer-secret-key>"
)
```

**3. Modify manifests:**

`manifests/01-management/xnat-upload.yaml.tpl` — remove the `AWS_ENDPOINT_URL` env var
(so boto3 defaults to real AWS S3):
```yaml
# DELETE this line:
#   - name: AWS_ENDPOINT_URL
#     value: "http://seaweedfs.seaweedfs.svc.cluster.local:8333"
```

`manifests/02-edge/xnat-ingest.yaml.tpl` — change the s3-uploader endpoint env to AWS S3:
```yaml
# Change the S3_ENDPOINT value to:
value: "https://s3.ap-southeast-2.amazonaws.com"
```

**4. Install — skip step 03 (SeaweedFS):**

When running `./install.sh`, press `s` at step 03 to skip SeaweedFS deployment.
Everything else remains the same.

### Advantages of AWS S3

- No SeaweedFS to manage, monitor, or back up
- Automatic redundancy and durability (11 nines)
- Cross-region replication available
- Pay-per-use (no disk provisioning)
- IAM policies are more granular than SeaweedFS's

### Advantages of SeaweedFS (self-hosted)

- Data never leaves your infrastructure (important for patient data pre-de-identification)
- No cloud costs
- No internet dependency between management and storage
- Full control over data residency and compliance

## TLS / Self-Signed CA

All edge ↔ management traffic flows over a single TLS port (443) multiplexed by
SNI. Three components make this work:

**1. Self-signed root CA — `ais-edge-ca`**
- Created by cert-manager at install time (script `02b-bootstrap-ca.sh`).
- 10-year duration, 4096-bit RSA, stored as a Secret in the `cert-manager` namespace.
- The PUBLIC half is exported to `ais-edge-ca.crt` (gitignored, distributed to edges).
- The PRIVATE half NEVER leaves the management node.

**2. Server certs (per service)**
- cert-manager issues 1-year RSA certs signed by `ais-edge-ca`.
- Auto-renewed 30 days before expiry — no site action required.
- Servers: `seaweedfs.aisedge.local` (and any future TLS-fronted service).
- The k0smotron-managed k0s API + konnectivity have their own internal CA — those
  certs include the aisedge.local hostnames as SANs (configured via `spec.k0sConfig.spec.api.sans`).

**3. Edge trust**
- Each edge cluster gets a Secret `xnat-ingest/ca-bundle` containing `ais-edge-ca.crt`.
- The `s3-uploader` pod mounts it at `/root/.mc/certs/CAs/ca.crt` so `mc` trusts our CA.
- Edge worker kubelet: standard k0s mTLS — kubelet uses the auto-generated kubeconfig
  CA cert (k0smotron's CA, not `ais-edge-ca`) for API server verification.

**Hostname resolution without DNS:**
- Edge VMs get a static `/etc/hosts` entry: `<MGMT_IP> seaweedfs.aisedge.local k0s.aisedge.local konnect.aisedge.local`
  (added by script `06-join-edge-worker.sh`).
- Pods on the edge cluster get `hostAliases` (in the manifest) for the same hostnames.
- The child cluster's CoreDNS gets a `hosts` plugin entry so the konnectivity-agent
  (which uses cluster DNS, not host /etc/hosts) can also resolve them.

**Trust chain at handshake time (e.g. mc upload from edge to SeaweedFS):**
```
edge mc client
  ├─ resolves seaweedfs.aisedge.local → MGMT_NODE_IP (via /etc/hosts in pod)
  ├─ opens TCP to MGMT_NODE_IP:443
  ├─ TLS ClientHello includes SNI=seaweedfs.aisedge.local
  ├─ mgmt nginx-ingress matches Ingress, terminates TLS using seaweedfs-tls Secret
  ├─ presents server cert (signed by ais-edge-ca)
  ├─ mc validates cert against /root/.mc/certs/CAs/ca.crt (= ais-edge-ca.crt)
  └─ chain verifies → S3 PUT proceeds over TLS
```

**CA rotation:**

When the CA is approaching expiry (or in a compromise scenario), use `scripts/rotate-ca.sh`:

```bash
# Phase 1: issue NEW CA + push bundle (old + new) to all edges
./scripts/rotate-ca.sh --phase=1

# Wait 14-30 days for renewal cycles to settle.
# During this window: BOTH CAs are trusted on edges. Server certs still
# signed by the OLD CA. Pipeline keeps working.

# Phase 2: switch the Issuer to NEW, re-issue all server certs, drop OLD from bundle
./scripts/rotate-ca.sh --phase=2
```

Use `--dry-run` first to preview. Test in staging before running in production.

## Observability

Optional log-aggregation, metrics, dashboarding, and alerting stack:

- **Loki** stores logs (chunks land in a SeaweedFS `logs-bucket`)
- **Prometheus** scrapes per-pod `/metrics` and stores time series
- **Grafana** queries both, hosts pre-built dashboards
- **Alertmanager** routes alerts via email (primary) and optional Slack
- **Vector** runs as a DaemonSet on every worker (mgmt + edge) and ships
  pod stdout to Loki over the same single 443 outbound port — adds two
  more SNI routes (`grafana.aisedge.local`, `loki.aisedge.local`) to the
  existing nginx-ingress; no new firewall rules.

The stack is optional. With `ALERT_EMAIL_TO` blank in `config/management.env`
the install script skips it cleanly. Set the email + SMTP vars and re-run
`./install.sh` (or `bash scripts/02d-install-observability.sh` and
`bash scripts/07b-deploy-edge-observability.sh <edge-entry>` directly).

Four dashboards land in Grafana under the `AIS Edge` folder:

- **Pipeline Overview** — cross-cluster counters and timeseries for the
  whole ingest pipeline (DICOMs vs S3 objects vs sessions, failures,
  invalid sessions, per-edge throughput, recent events log).
- **Edge Site Drilldown** — single-cluster + per-worker-node view with
  dropdowns for `cluster` and `node`.
- **Session Timeline** — single-session trace across edges and mgmt by
  session name.
- **SeaweedFS Health** — storage-layer metrics from Prometheus.

For exactly what every panel measures, including the s3-uploader event
schema and the difference between the `dicoms` and `files` fields, see
[`docs/dashboards.md`](docs/dashboards.md). For the architectural reason
edge-side alerts live in Loki ruler instead of mgmt Prometheus, see
[`docs/alerting-architecture.md`](docs/alerting-architecture.md). For
per-component detail (what each one stores, what it has access to, what
the failure modes are, how to scale or replace it), see
[`docs/components/`](docs/components/).

## Konnectivity and Middleboxes

Konnectivity is the reverse tunnel that lets the management API server reach
back into worker components (`kubectl exec`, `kubectl logs`, `kubectl
port-forward`, metrics scraping). On the edge it runs as
`konnectivity-agent`, which dials out to `https://konnect.aisedge.local:443`
and keeps a long-lived **HTTP/2 + gRPC over TLS** connection open. The
management nginx-ingress forwards the raw TLS bytes through to the
konnectivity-server inside the hosted control plane (SSL passthrough — nginx
never decrypts).

This protocol works through every standards-compliant firewall, but a few
classes of network appliance can disrupt it. Worth flagging for site IT:

- **Deep-packet-inspection / TLS-intercepting proxies.** Devices that
  terminate TLS to scan traffic break the tunnel. Konnectivity uses mutual
  cert verification; an interception proxy presents its own cert which the
  agent will reject (`x509: certificate signed by unknown authority`). The
  fix at the site is either to **bypass interception for the management
  IP** or **install the proxy's CA into the agent's trust store**, but the
  cleanest answer is bypass.
- **Aggressive HTTP/2 stream timeouts.** Some firewalls and L7 load
  balancers drop HTTP/2 streams that are idle for a few minutes. The
  konnectivity tunnel uses long-lived streams (often >1h) for keepalive
  and watch traffic. If the appliance kills the stream, kubelet briefly
  disconnects from the control plane and the agent reconnects — usually
  invisible, but `kubectl exec` and `kubectl logs` may stall during the
  reconnect. Configure the appliance with **idle timeout ≥ 60 minutes**
  on outbound 443 to the management IP.
- **gRPC-aware filtering / QUIC enforcement.** A few enterprise proxies
  block gRPC on port 443 by default, or rewrite responses to force
  HTTP/1.1. Konnectivity requires HTTP/2 end to end; HTTP/1.1 downgrade
  breaks it. Allow plain HTTPS/HTTP-2 to the management IP without
  protocol rewriting.
- **Stateful firewalls with short connection-tracking tables.** Same idle-
  timeout class of issue as above. A flow that sees no packets for ~5 min
  may get evicted from the conntrack table; keepalive on the agent should
  prevent it but is occasionally too sparse on tightly-tuned appliances.

If `kubectl logs` or `kubectl exec` against a child cluster suddenly stops
working ("No agent available" in the API server logs), check the
konnectivity-agent pod: `KUBECONFIG=kubeconfig-<edge> kubectl get pods -n
kube-system -l k8s-app=konnectivity-agent`. Restarts on the agent are the
classic symptom of a middlebox kicking the tunnel.

The data path (DICOM upload via `mc mirror` to SeaweedFS) does NOT use
konnectivity — it is plain HTTPS REST and tolerates short connection drops
naturally. Konnectivity disruption affects only central-admin visibility, not
data integrity.

## Uninstall

```bash
./scripts/uninstall.sh
```

This removes everything: edge workers, SeaweedFS data, hosted clusters, k0smotron, and
optionally k0s itself (if installed fresh). Resources removed include:
- ingress-nginx (helm release + namespace)
- ais-edge-ca Issuer + Secret + exported `ais-edge-ca.crt`
- /etc/hosts entries on management and edge VMs
- /etc/haproxy/certs/ on each edge worker

## Network Ports

A single TLS port carries all edge ↔ management traffic. SNI on the
nginx-ingress controller routes to the right backend.

| From | To | Port | Purpose | Encrypted? |
|------|-----|------|---------|---|
| Edge | Management | **443** | All edge traffic, SNI-routed: `seaweedfs.aisedge.local`, `k0s.aisedge.local`, `konnect.aisedge.local` | TLS — server cert signed by `ais-edge-ca` |
| Management | XNAT | 443 | XNAT REST API uploads | HTTPS |
| Management | Edge | 22 | SSH (initial setup only) | SSH |

All edge traffic is **outbound only** (zero inbound on edge VMs).

**Site IT firewall rule:** ALLOW outbound TCP from edge IP to management IP, dst-port 443.

Admin-only endpoints (SeaweedFS master/filer UIs, S3 admin) are now ClusterIP-only on the
management cluster — reach them via `kubectl port-forward`. No external port required.
