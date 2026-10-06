# Orthanc

## Overview

[Orthanc](https://www.orthanc-server.com/) is a lightweight,
open-source DICOM server. In ais-edge it sits at the edge of each site,
acts as the **DICOM receiver** for local modalities, and runs the AIS
**deidentification Lua hook** before xnat-ingest groups and stages the data.

We use the [`jodogne/orthanc-plugins`](https://hub.docker.com/r/jodogne/orthanc-plugins)
image (pinned to a version ≥ 1.12.0 because the deid hook uses
**study-level labels**, introduced in 1.12.0).

## Role in this stack

Three jobs at each edge:

1. **DIMSE C-STORE SCP** on host port 4242 with `AET=AISEDGE`. Modalities
   on the local facility LAN push studies here.
2. **Lua `OnStoredInstance` hook** writes the ORIGINAL DICOM to
   `/facility-backup` (site-controlled retention) and runs
   `/instances/{id}/modify` to produce a deidentified copy. The
   original is deleted from Orthanc; the deid'd instance is kept.
3. **Lua `OnStableStudy` hook** PUTs the `xnat-ingest-ready` label on each
   study once it's been quiescent for `StableAge` seconds. This is the
   signal for `xnat-ingest group-orthanc` to REST-pull the study.

After `group-orthanc` hardlinks the instances into `/data/grouped/`, it
PUTs the `xnat-ingest-processed` label on the study so subsequent
`group-orthanc` cycles skip it. `xnat-ingest assign` then collates the
grouped session into `/data/assigned/` — the stage the edge s3-uploader
syncs to SeaweedFS. (There is no `staging/` directory on the edge;
"staged" refers to the S3 side. See [xnat-ingest.md](xnat-ingest.md).)

```
Modality ──C-STORE──► Orthanc :4242 (AET=AISEDGE)
                          │
                          ├─ OnStoredInstance:
                          │   1. backup → /facility-backup
                          │   2. /modify (deid; UIDs kept) → new instance, same Study
                          │   3. delete ORIGINAL
                          │
                          └─ OnStableStudy (after StableAge=30s silence):
                              PUT /studies/{id}/labels/xnat-ingest-ready
                                                      │
                                                      ▼
                                xnat-ingest group-orthanc REST-pulls,
                                hardlinks, PUTs label xnat-ingest-processed
```

## What Orthanc has access to

| Resource | Why |
|---|---|
| Host network port 4242 (`hostPort`) | Modality C-STORE inbound from local facility LAN |
| The shared pipeline PVC, mounted at `/data` (hostPath `/data/xnat-ingest`) | Orthanc writes its DICOM storage tree to `/data/orthanc-storage`. It is the **same claim every ingest stage mounts**, which is what guarantees `orthanc-storage/`, `grouped/` and `assigned/` share one filesystem — a hardlink cannot cross a filesystem boundary (EXDEV), and `hardlink_or_copy` would silently degrade to a full byte copy of every study |
| hostPath `/data/facility-backup` mounted as `/facility-backup` | Canonical local copy of every received original DICOM. Site-controlled retention. Independent of AIS lifecycle. |
| Three ConfigMaps, mounted at **two** paths | `orthanc-config` (orthanc.json) and `orthanc-scripts` (the Lua hook) under `/etc/orthanc/`; `orthanc-routing` — which carries **both** `routing.json` and `deidentification-profile.json` — under `/etc/ais-edge/`. The split is load-bearing, not tidiness: see "Configuration" below |
| One Secret env var | `AIS_DEID_HMAC_SALT` — per-deployment salt for SubjectHash / SessionHash derivation in the Lua hook |
| One mounted Secret | `orthanc-credentials` → `/etc/orthanc-credentials/users.json`, named by Orthanc's `RegisteredUsersFile`. The REST API can delete studies, so it is authenticated rather than protected only by being ClusterIP-only |
| No outbound network | Doesn't talk to XNAT, doesn't talk to other AIS pods. xnat-ingest group-orthanc talks to it (in-cluster Service). |

## Where it runs

Single pod (`Recreate` strategy — hostPath isn't shareable across
replicas), one per edge worker. Deployed by the edge chart; template at
[`charts/edge/templates/orthanc-deployment.yaml`](../../charts/edge/templates/orthanc-deployment.yaml).

REST API exposed as a ClusterIP Service
`edge-orthanc.xnat-ingest.svc.cluster.local:8042` — every Orthanc object
is **release-prefixed** (`{{ include "edge.fullname" . }}-orthanc`), and
`install.sh` installs the edge chart as release `edge`, so the objects
are `deploy/edge-orthanc` and `svc/edge-orthanc`. That prefixed address
is exactly what the chart passes to `group-orthanc`; a site installed
under a different release name shifts both.

DICOM port 4242 is exposed via `hostPort` directly on the edge node IP
so modalities can reach it without an in-cluster Service. (The Service
flips to `NodePort` if `orthanc.expose.dicom` or `orthanc.expose.http`
asks for it — the default keeps the REST API in-cluster only.)

## Configuration

Nothing here is edited as a file. [`charts/edge/templates/orthanc-config.yaml`](../../charts/edge/templates/orthanc-config.yaml)
renders three ConfigMaps from `sites/<site>/values.yaml`, so the site file is
the only thing you change. (These used to be hand-edited copies under
`config/orthanc/`; that directory is gone — it fed nothing, and editing the
copy of the Lua script it held changed nothing at all.)

**Why the three ConfigMaps land on two paths.** Orthanc is started with
a *directory* as its configuration argument and merges every `*.json` in
it as server configuration — verified on a running edge:

```
Scanning folder "/etc/orthanc" for configuration files
Reading the configuration from: "/etc/orthanc/orthanc.json"
Reading the configuration from: "/etc/orthanc/deidentification-profile.json"
Reading the configuration from: "/etc/orthanc/routing.json"
```

So the old single-path layout had Orthanc ingesting our AET routing
table and our de-identification profile as *server settings*. It is
harmless today only by accident — none of `AETMap`, `Defaults`, `Keep`,
`Replace`, `Force`, `DeidMode` or `RemovePrivateTags` collides with a
real Orthanc setting — but the scan order is filesystem order, so a
future key that did collide would reconfigure the server silently and
non-deterministically. Hence: `/etc/orthanc/` holds **only**
`orthanc.json` plus `scripts/`, and `/etc/ais-edge/` holds
`routing.json` plus `deidentification-profile.json`, which our Lua hook
reads by path and Orthanc never scans.

| Rendered file | Built from | What it does |
|---|---|---|
| `orthanc.json` | `orthanc.*` and `dataPolicy.derived.orthancStorage.*` | Daemon config: AET, ports, storage path, `StableAge`, points at the Lua script |
| `deidentify-and-forward.lua` | `.Files.Get "files/deidentify-and-forward.lua"` | The deid + label hook. **Identical across all AIS-Edge deployments** — no site-specific bits, which is why it is a chart file and not a value |
| `routing.json` | `orthanc.deid.aetMap` | **Per-site**: maps modality AETs → XNAT project. Set one entry per modality; an unmapped AET is quarantined, not dropped. Mounted at `/etc/ais-edge/`, not `/etc/orthanc/` |
| `deidentification-profile.json` | `orthanc.deid.profile` | The site's deid contract — Replace + Keep blocks following Orthanc's `/modify` API, applied to every accepted study. Defaults to `{}`, which the chart **refuses to render**: an empty profile hands `/modify` nothing to change, so studies would reach XNAT with PHI intact and nothing would look wrong. Start from `charts/edge/files/deidentification-profile.example.json`. Rendered into the same `orthanc-routing` ConfigMap as `routing.json` |

Two Secrets, both from `sites/<site>/secrets.enc.yaml`:

**`orthanc-deid-salt`** (`orthanc.deid.existingSaltSecret`, key
`AIS_DEID_HMAC_SALT`) — the per-deployment salt for SubjectHash /
SessionHash derivation in the Lua hook. Generate with
`openssl rand -hex 32`. Rotating it means a different deid'd identity
for the same patient, so only rotate deliberately.

**`orthanc-credentials`** (`orthanc.auth.existingSecret`) — **three
keys, not two**, because two different things consume it:

| Key | Consumed by |
|---|---|
| `users.json` | Orthanc itself, mounted at `/etc/orthanc-credentials/users.json` and named by `RegisteredUsersFile`. Shape: `{"RegisteredUsers":{"admin":"<password>"}}`. The password is **plaintext inside that JSON**, which is why this Secret belongs in the SOPS-encrypted site file |
| `orthanc-user`, `orthanc-password` | `xnat-ingest group-orthanc`, which calls the REST API to list and label studies |

If those disagree with the user in `users.json`, Orthanc answers 401 and
the pipeline stalls with data sitting in Orthanc and nothing else
reporting an error. A Secret built with only the last two keys installs
cleanly and *then* Orthanc fails to start, because `RegisteredUsersFile`
points at a path the volume never supplied — which is why the chart
fails the render outright when `orthanc.auth.enabled` names no Secret.

## Operations

```bash
# Pod state
kubectl --kubeconfig kubeconfig-edge-<site> get pods -n xnat-ingest -l app=orthanc

# Logs (deid events: instance_deidentified, study_labeled_ready)
# Object names are release-prefixed — `edge` is the release install.sh uses.
kubectl --kubeconfig kubeconfig-edge-<site> logs -n xnat-ingest deploy/edge-orthanc

# Orthanc Explorer UI (port-forward + browser). Auth is ON: log in with the
# user from the orthanc-credentials Secret's users.json.
kubectl --kubeconfig kubeconfig-edge-<site> port-forward -n xnat-ingest svc/edge-orthanc 8042:8042
# → http://localhost:8042/app/explorer.html

# DICOM endpoint smoke-test from a modality side or with dcmtk
storescu -aec AISEDGE -aet TEST_MOD <edge-ip> 4242 /path/to/study/*.dcm
```

## Known limitations

- **No automatic cleanup** of deid'd instances in Orthanc storage after upload to XNAT. Manual or scripted cleanup needed for production (e.g. delete studies labelled `xnat-ingest-processed` once confirmed in XNAT).
- **Pure-Lua salted hash instead of true HMAC** for SubjectHash / SessionHash, because `jodogne/orthanc-plugins` doesn't expose `Compute*` crypto in Lua. Adequate for research deid; switch to `jodogne/orthanc-python` for HMAC-grade.
- **Profile authoring is by hand** — no validation that referenced DICOM tags exist in Orthanc's dictionary before deployment. What replaced the old `07c` prompt is a **render-time gate**: `deid.policyReviewed` (`charts/edge/values.yaml`, top level, not under `orthanc:`, because it gates every engine) has no safe default and the chart refuses to install until a human sets it true, confirming the profile and AET map match the site's policy (`charts/edge/templates/_helpers.tpl`). The same guard also fails an empty `aetMap` — every modality would be quarantined as unmapped — and an empty `profile`. It is a gate, not a validator: it confirms a human read the profile, not that the tags in it exist.
- **Hardlinks require a shared filesystem** — `orthanc-storage/`, `grouped/` and `assigned/` must live on one mount, or group-orthanc's `hardlink_or_copy` degrades to a full byte copy (and a true hardlink would fail with EXDEV). This is structurally guaranteed rather than left to the operator: every stage mounts the **same pipeline PVC** at `/data`, backed by `storage.pipeline.hostPath: /data/xnat-ingest`. Splitting them across volumes is the way to break it.
- **Modalities with unmapped CalledAETs are rejected for ingest, but not discarded** — the original instance is written to `<FacilityBackupDir>/__unmapped_aet__/<AET>/<PatientID>/<StudyUID>/<SOPUID>.dcm` and only then removed from Orthanc. If that quarantine write fails the instance is kept in Orthanc instead, and if no `FacilityBackupDir` is configured the hook aborts without deleting anything. A `REJECT: no project mapped for CalledAET <AET>` line is logged, which is what the `DICOMRejectedUnmappedAET` alert matches. Add the AET to `routing.json` AETMap and re-send to ingest the quarantined studies.
- **`AIS_DEID_HMAC_SALT` rotation breaks subject linkage** — rotating the salt produces a different SubjectHash for the same patient. Rotate only deliberately.
