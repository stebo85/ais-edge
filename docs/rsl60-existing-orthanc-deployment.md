# rsl60 Deployment With Existing Orthanc

This runbook is for the XNAT-host deployment shape:

- The XNAT server's existing `k3s` cluster is the AIS Edge management cluster.
- `rsl60` is the facility edge worker, but it is behind a firewall and cannot be reached by SSH from the XNAT host.
- Orthanc is already running on `rsl60`, so AIS Edge must not deploy its own Orthanc pod or bind port `4242`.

## Configuration

Use these settings in `config/management.env`:

```bash
export INSTALL_MODE="existing"
export INSTALL_TOPOLOGY="cloud"
export CLOUD_PROVIDER="none"
```

Use these settings in `config/edge-nodes.env`:

```bash
EDGE_NODES=(
  "edge-rsl60|rsl60|ubuntu||<XNAT_PROJECT>|<RSL60_S3_ACCESS_KEY>|<RSL60_S3_SECRET_KEY>"
)

export EDGE_JOIN_MODE="manual"
export AIS_EDGE_NO_SSH="1"
export EDGE_ORTHANC_MODE="external"
export EDGE_ORTHANC_URL="http://<rsl60-orthanc-api-host-or-ip>:8042"
export EDGE_DATA_HOST_PATH="/data/xnat-ingest"
export EDGE_ORTHANC_STORAGE_HOST_PATH="/data/xnat-ingest/orthanc-storage"
export EDGE_ORTHANC_STORAGE_DIR="/data/orthanc-storage"
```

The existing Orthanc storage must be visible to the sort pod at
`EDGE_ORTHANC_STORAGE_DIR`. The safest layout is to bind-mount the existing
Orthanc storage on `rsl60` to:

```bash
/data/xnat-ingest/orthanc-storage
```

Keep staging and Orthanc storage on the same filesystem. `xnat-ingest sort`
hardlinks from Orthanc storage into staging, and cross-filesystem hardlinks
fail with `EXDEV`.

## Management-Side Steps

Run from the XNAT host with `kubectl` pointed at the existing k3s cluster.
On this host that may mean:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

Then:

```bash
bash scripts/01-install-k0s.sh
bash scripts/02-install-k0smotron.sh
bash scripts/02b-bootstrap-ca.sh
# Review ingress-nginx carefully before this step on the XNAT host.
bash scripts/02c-install-nginx-ingress.sh
bash scripts/03-deploy-seaweedfs.sh
bash scripts/04-deploy-xnat-upload.sh

entry='edge-rsl60|rsl60|ubuntu||<XNAT_PROJECT>|<RSL60_S3_ACCESS_KEY>|<RSL60_S3_SECRET_KEY>'
bash scripts/05-setup-edge-cluster.sh "$entry"
bash scripts/06a-create-edge-bootstrap-bundle.sh "$entry"
```

Transfer `secrets/edge-bootstrap-edge-rsl60.tar.gz` to `rsl60` using a
facility-approved path.

## rsl60 Local Step

Run locally on `rsl60`:

```bash
tar xzf edge-bootstrap-edge-rsl60.tar.gz
cd edge-bootstrap-edge-rsl60
./bootstrap-rsl60.sh
```

This installs the k0s worker, joins it to the hosted control plane, prepares
staging directories, and leaves the existing Orthanc service untouched.

## Finish From XNAT Host

After the local bootstrap:

```bash
KUBECONFIG=kubeconfig-edge-rsl60 kubectl get nodes -o wide
AIS_EDGE_NO_SSH=1 bash scripts/07-deploy-edge-ingest.sh "$entry"
AIS_EDGE_NO_SSH=1 bash scripts/07b-deploy-edge-observability.sh "$entry"  # optional
bash scripts/07c-deploy-edge-orthanc.sh "$entry"  # should print SKIPPED
```

Check:

```bash
KUBECONFIG=kubeconfig-edge-rsl60 kubectl get pods -n xnat-ingest -o wide
KUBECONFIG=kubeconfig-edge-rsl60 kubectl logs -n xnat-ingest -l component=sort -f
KUBECONFIG=kubeconfig-edge-rsl60 kubectl logs -n xnat-ingest -l component=s3-uploader -f
kubectl logs -n xnat-upload -l component=upload -f
```

## Orthanc Requirements

The existing Orthanc must provide:

- An HTTP API reachable from the sort pod at `EDGE_ORTHANC_URL`.
- Storage readable from the k0s worker host path configured by `EDGE_ORTHANC_STORAGE_HOST_PATH`.
- The expected labels `xnat-ingest-ready` and `xnat-ingest-skip`, unless the
  sort command is deliberately reconfigured after confirming unlabeled polling
  is safe for that Orthanc instance.
