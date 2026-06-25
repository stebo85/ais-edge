# Orthanc

## Overview

[Orthanc](https://www.orthanc-server.com/) is a lightweight,
open-source DICOM server. In ais-edge it sits at the edge of each site,
acts as the **DICOM receiver** for local modalities, and runs the AIS
Lua hook that labels stable studies for `xnat-ingest sort`.

The facility scanners are expected to send already-deidentified DICOMs.
AIS Edge does not alter DICOM tags in Orthanc.

We use the [`jodogne/orthanc-plugins`](https://hub.docker.com/r/jodogne/orthanc-plugins)
image pinned to a version >= 1.12.0 because the hook uses study-level
labels, introduced in Orthanc 1.12.0.

## Role in this stack

Three jobs at each edge:

1. **DIMSE C-STORE SCP** on host port 4242 with `AET=AISEDGE`. Modalities
   on the local facility LAN push studies here.
2. **Lua `OnStableStudy` hook** PUTs the `xnat-ingest-ready` label on each
   study once it has been quiescent for `StableAge` seconds. The hook does
   not modify, delete, back up, or re-store DICOM instances.
3. **`xnat-ingest sort`** REST-pulls labelled studies and hardlinks the
   instances into staging.

After sort hardlinks the instances into `/data/staging/`, it PUTs the
`xnat-ingest-skip` label on the study so subsequent sort cycles skip it.

```
Modality ──C-STORE──► Orthanc :4242 (AET=AISEDGE)
                          │
                          └─ OnStableStudy (after StableAge=30s silence):
                              PUT /studies/{id}/labels/xnat-ingest-ready
                                                      │
                                                      ▼
                                xnat-ingest sort REST-pulls, hardlinks,
                                PUTs label xnat-ingest-skip
```

## What Orthanc has access to

| Resource | Why |
|---|---|
| Host network port 4242 (`hostPort`) | Modality C-STORE inbound from local facility LAN |
| hostPath `/data/xnat-ingest/orthanc-storage` mounted as `/data/orthanc-storage` | Orthanc's DICOM storage tree. **Must be on the same filesystem as xnat-ingest staging** so hardlinks work (cross-fs hardlink fails with EXDEV) |
| Two ConfigMaps mounted under `/etc/orthanc/` | `orthanc-config` (orthanc.json), `orthanc-scripts` (Lua) |
| No outbound network | Doesn't talk to XNAT or other AIS pods. `xnat-ingest sort` talks to it through the in-cluster Service. |

## Where it runs

Single pod (`Recreate` strategy because hostPath is not shareable across
replicas), one per edge worker. Deployed by
`scripts/07c-deploy-edge-orthanc.sh`. Manifest at
[`manifests/02-edge/orthanc.yaml.tpl`](../../manifests/02-edge/orthanc.yaml.tpl).

REST API exposed as a ClusterIP Service `orthanc.xnat-ingest.svc.cluster.local:8042`.
DICOM port 4242 is exposed via `hostPort` directly on the edge node IP
so modalities can reach it without an in-cluster Service.

## Configuration

Site-shipped files live in [`config/orthanc/`](../../config/orthanc/)
and are turned into ConfigMaps by the deploy script.

| File | What it does |
|---|---|
| `orthanc.json` | Daemon config: AET, ports, storage path, `StableAge=30`, points at the Lua script |
| `deidentify-and-forward.lua` | Legacy filename; current behavior is label-only and identical across AIS-Edge deployments |

## Operations

```bash
# Pod state
kubectl --kubeconfig kubeconfig-edge-<site> get pods -n xnat-ingest -l app=orthanc

# Logs
kubectl --kubeconfig kubeconfig-edge-<site> logs -n xnat-ingest deploy/orthanc

# Orthanc Explorer UI (port-forward + browser)
kubectl --kubeconfig kubeconfig-edge-<site> port-forward -n xnat-ingest svc/orthanc 8042:8042
# -> http://localhost:8042/app/explorer.html

# DICOM endpoint smoke-test from a modality side or with dcmtk
storescu -aec AISEDGE -aet TEST_MOD <edge-ip> 4242 /path/to/study/*.dcm
```

## Known Limitations

- **No automatic cleanup** of instances in Orthanc storage after upload to XNAT. Manual or scripted cleanup is needed for production, for example deleting studies labelled `xnat-ingest-skip` once confirmed in XNAT.
- **AIS Edge trusts upstream deidentification**. The Lua hook does not inspect or scrub DICOM tags.
- **Hardlinks require shared filesystem**. `/data/xnat-ingest/orthanc-storage` and `/data/xnat-ingest/staging` must live on the same physical mount, or sort fails with EXDEV.
