# AIS Edge — medical imaging ingest from hospital to XNAT

Receives DICOM inside a hospital, de-identifies it at the point of capture, and
delivers it to XNAT — without the hospital network ever needing an inbound
route, and without XNAT credentials ever leaving the management node.

---

> **New here?** Read [docs/TOUR.md](docs/TOUR.md) first — a guided walkthrough
> of what you configure, what runs, what can go wrong, and where the data goes.

## Contents

- [What this is](#what-this-is)
- [Deployment topology](#deployment-topology)
- [Architecture](#architecture)
- [Data flow, step by step](#data-flow-step-by-step)
- [Install](#install)
- [Configuration reference](#configuration-reference)
- [Secrets](#secrets)
- [Data policy — what is kept and for how long](#data-policy--what-is-kept-and-for-how-long)
- [Security model](#security-model)
- [Observability and alerting](#observability-and-alerting)
- [Repository structure](#repository-structure)
- [Continuous integration](#continuous-integration)
- [Operating](#operating)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Pinned versions](#pinned-versions)

---

## What this is

A **management node** runs the central services: S3 staging, the XNAT uploader,
the observability stack, the internal certificate authority, and one k0smotron
*hosted control plane* per edge site.

An **edge** is a single machine inside a hospital network running Orthanc and
the ingest pipeline. It has no inbound route from the internet. It reaches the
management node outbound over TLS, and its Kubernetes control plane physically
runs on the management node — so the hospital operates a Kubernetes node without
operating a Kubernetes cluster.

The de-identification happens **on the edge, before anything leaves the site**.
The original is written to a facility backup that is never automatically
deleted; everything downstream is derived data.

---

## Deployment topology

### Tier 2 — fleet (this repo's primary mode)

Many hospitals, one management node, one XNAT credential for the whole fleet.

```
   Hospital A                Hospital B                Hospital C
   ┌──────────┐              ┌──────────┐              ┌──────────┐
   │ edge-a   │              │ edge-b   │              │ edge-c   │
   │ Orthanc  │              │ Orthanc  │              │ Orthanc  │
   └────┬─────┘              └────┬─────┘              └────┬─────┘
        │  outbound HTTPS only    │                         │
        └────────────┬────────────┴─────────────────────────┘
                     ▼
        ┌────────────────────────────────────┐
        │      MANAGEMENT NODE               │
        │  SeaweedFS   s3://ingest-<edge>/   │
        │  uploader    per edge → XNAT       │
        │  reclaimer   per edge              │
        │  k0smotron   a control plane each  │
        │  Prometheus · Loki · Grafana       │
        │  cert-manager (internal CA)        │
        └───────────────┬────────────────────┘
                        ▼
                      XNAT
```

Each edge gets its **own S3 bucket, own identity, own uploader, own reclaimer,
own control plane**. One site's stuck session, expired credential or poison
study cannot stop delivery for any other site.

### Tier 1 — single site

One machine, no management node. Install `charts/edge` alone with
`upload.mode: direct`, and the edge talks to XNAT itself. This repo's management
chart is not needed.

---

## Architecture

| Component | Where | Role |
|---|---|---|
| **Orthanc** | edge | DICOM C-STORE receiver on :4242. Runs the de-identification Lua hook on every stored instance. |
| **deidentify-and-forward.lua** | edge | Writes the untouched original to the facility backup, then rewrites identity tags per the site's profile, then labels the study for pickup. |
| **group-orthanc** | edge | Pulls studies labelled `xnat-ingest-ready` out of Orthanc into `/data/grouped`, then labels them `xnat-ingest-processed` so they are not pulled twice. |
| **assign** | edge | Groups instances into XNAT sessions under `/data/assigned`, writing `__MANIFEST__.json` (per-resource, with MD5 checksums) and `__METADATA__.json`. |
| **s3-uploader** | edge | `aws s3 sync` each settled session to `s3://ingest-<edge>/staged/`. Emits a JSON event schema that the alert rules consume. |
| **Vector** | edge | Ships pod logs to Loki on the management node over TLS. |
| **SeaweedFS** | mgmt | S3 staging. One bucket per edge, one scoped identity per edge. |
| **mgmt-upload-\<edge\>** | mgmt | `xnat-ingest upload` — pulls staged sessions and writes them into XNAT. |
| **mgmt-reclaim-\<edge\>** | mgmt | Removes staged sessions **only after XNAT confirms it holds every file**. The only component that deletes patient data. |
| **staged-reclaimer** | edge | The same script as `mgmt-reclaim-<edge>`, run with `STORAGE=filesystem` against the terminal stage directory. Renders **only under `upload.mode: direct`**, where there is no bucket and no s3-uploader to write an `uploaded` marker, so `onUploaded` would otherwise be unsatisfiable and the tree would grow unbounded. Also deletes patient data, under the same XNAT confirmation. |
| **cert-sync** | mgmt | Copies the CA bundle, each edge's Loki push **client certificate**, and that edge's **S3 key pair** into that edge's cluster, on a schedule, so CA rotation does not require visiting sites. |
| **k0smotron** | mgmt | Hosts a k0s control plane per edge. The edge runs only a worker. |
| **cert-manager** | mgmt | Issues the internal CA and every server certificate. |

### Why the control plane is hosted centrally

An edge is a box in a hospital basement that nobody logs into. Running its API
server on the management node means:

* the hospital does not operate etcd, certificates or control-plane upgrades;
* the edge needs no inbound firewall rule — the worker dials out through
  konnectivity;
* losing the edge machine loses a worker, not a cluster.

---

## Data flow, step by step

```
 1. modality ──C-STORE──▶ Orthanc :4242
                             │
 2.                          ├──▶ /data/facility-backup/<study>/…    ORIGINAL
 3.                          │     written FIRST, before de-identification
                             │     governed by dataPolicy.originals (forever)
                             ▼
 4.              de-identify in place (Lua, OnStoredInstance)
                             │   identity tags replaced per site profile
                             │   UIDs retained so a study stays coherent
                             ▼
 5.              label study `xnat-ingest-ready`
                             │
 6.  group-orthanc ──────────┘   (waits for IsStable; skips already-processed)
        │
        ▼
 7.  /data/grouped/<session>/
        │
 8.  assign
        ▼
 9.  /data/assigned/<project>.<subject>.<visit>/
        │   + __MANIFEST__.json  (filenames + MD5 per resource)
        │   + __METADATA__.json
        │
10.  s3-uploader   waits settleMinutes, fingerprints the tree, uploads
        │          HTTPS, per-site credential, custom CA
        ▼
11.  s3://ingest-<edge>/staged/<session>/
        │
12.  mgmt-upload-<edge>  ──▶ XNAT
        │
13.  mgmt-reclaim-<edge>  re-queries XNAT, compares filenames AND checksums
                          against the manifest, and only then deletes
```

**Every hop is idempotent and fails safe.** If the S3 endpoint is unreachable,
the uploader keeps the local copy and retries. If XNAT is down, staged data
accumulates rather than being lost. If the reclaimer cannot prove XNAT holds a
session, it keeps it.

---

## Install

```bash
./install.sh <site>        # interactive, one prompt per step
./install.sh -y <site>     # non-interactive
```

**One file configures a deployment: `sites/<site>/values.yaml`.** `install.sh`
reads it *and* passes it to both Helm charts, so every fact is stated once.
There is no `--set` anywhere in the installer — a flag needed to make an install
work is a value that belongs in the site file, and an install you cannot
reproduce from that file alone is not reproducible.

### First-time setup

```bash
# 0. On the MANAGEMENT node: the two tools the secrets step needs. Nothing else
#    installs them, and step 2 is the first command that fails without them.
sudo apt-get install -y age
curl -fsSLO https://github.com/getsops/sops/releases/download/v3.13.3/sops_3.13.3_amd64.deb
sudo apt-get install -y ./sops_3.13.3_amd64.deb

# 1. Get the repo. `main` is this tier; tier-1 (a single node, no management
#    cluster) lives on the `tier-1-solution` branch and is not interchangeable.
git clone <repo-url> && cd ais-edge

# 2. Create your age key and register it as a SOPS recipient
scripts/site-secrets.sh init-key
scripts/site-secrets.sh add-recipient <your age1... public key>

# 3. Scaffold the MANAGEMENT site (copies sites/example-mgmt/)
scripts/site-secrets.sh new my-site mgmt

# 4. Add each EDGE. PREFER add-edge OVER `new <name> edge`: it does this step and
#    the S3 wiring in one go, GENERATING the key pair rather than making you type
#    the same one into two files.
scripts/site-secrets.sh add-edge my-site my-edge

#    `new my-edge edge` also works, and then the edge's name has to be made to
#    agree in FIVE places by hand. Renaming an edge means editing all of them:
#      sites/my-site/values.yaml       edges[].name
#      sites/my-site/values.yaml       edges[].s3SecretRef
#      sites/my-site/secrets.enc.yaml  that Secret's metadata.name
#      sites/my-edge/values.yaml       clusterLabel
#      the site directory name itself
#    Getting one wrong RENDERS CLEANLY: the management chart provisions a control
#    plane for an edge that never checks in, and the edge asks for one that was
#    never provisioned.

# 5. Edit them. The management file carries everything shared — domain,
#    hostnames, node IPs, the edges list, the fleet-wide data policy. Each edge
#    file carries only what is local to that site: its AE-title to XNAT-project
#    map, its de-identification profile, its disk paths.
$EDITOR sites/my-site/values.yaml        $EDITOR sites/my-site/secrets.enc.yaml
$EDITOR sites/my-edge/values.yaml        $EDITOR sites/my-edge/secrets.enc.yaml

# 6. Encrypt — do this before committing anything
scripts/site-secrets.sh encrypt my-site
scripts/site-secrets.sh encrypt my-edge

# 7. Install
./install.sh my-site

# 8. PROVE IT WORKS. Do not skip this — `helm install` succeeding only means the
#    objects were accepted, not that the fleet is actually working.
make verify-live SITE=my-site
```

> **Back up `~/.config/sops/age/keys.txt`.** It is the only key that can decrypt
> `sites/*/secrets.enc.yaml`, nothing can regenerate it, and losing it makes
> every encrypted site file permanently unreadable. Put it in the team password
> manager.

### Then verify, every time

```bash
make verify-live SITE=my-site        # or: scripts/verify-live.sh my-site
```

This is the difference between "Helm accepted the manifests" and "a study sent
to an edge will reach XNAT". It reads the SAME `sites/<site>/values.yaml` the
install used, so it checks *your* hostnames, namespaces and edge list — nothing
in it is hardcoded, and a deployment that keeps its data somewhere other than
`/data` is checked where it actually lives.

On this tier it walks the whole fleet: the management API server, node
readiness, pod health per namespace, the `ais-edge-ca` Certificate and every
Certificate derived from it, the SeaweedFS S3 Service, each edge's hosted
control plane, and XNAT reachability. Its exit code is the number of failures.

Run it:

* after `install.sh`, always;
* after adding an edge — a `join: bundle` edge in particular, because nothing
  on the management side can tell you the operator actually ran the bundle;
* after rotating a Secret or the CA;
* after a reboot of the management node or any edge.

> The edges' DICOM receivers listen on a **`hostPort`**, which is invisible from
> inside the cluster, so verify-live cannot confirm them and does not pretend to.
> Prove that leg with a real C-STORE from a machine that will send studies.

### What each step does, and why it is not all Helm

| Step | Does | Why it cannot be a chart |
|---|---|---|
| **1** | k0s, kubectl, helm, local-path-provisioner | there is no cluster yet |
| **2** | cert-manager, then the k0smotron operator — both pinned | there are no CRDs yet, and cert-manager must exist **before** the chart |
| **3** | site Secrets, SOPS → cluster | must precede the workloads that mount them |
| **4** | `helm install` management chart | — |
| **5** | child kubeconfig + join token, per edge | a Helm-rendered token would be re-minted on every upgrade |
| **6** | join the edge worker — over SSH (`join: ssh`, the default), or by a self-contained bundle you carry to the site and run there (`join: bundle`, see **Edges** below) | the worker has to be joined from outside the cluster; with `join: bundle` the management node never touches it at all |
| **7** | `helm install` edge chart, then seed cert-sync | — |

#### Why cert-manager is a prerequisite, not a subchart

The dependency is circular, and the loop is not obvious:

```
management chart renders `Cluster` (k0smotron.io) objects
  └─▶ that CRD declares a CONVERSION WEBHOOK
       └─▶ served by the k0smotron operator
            └─▶ which will not start until cert-manager issues its serving cert
                 └─▶ and cert-manager would be installed by the same chart
```

Setting `certManager.enabled: true` therefore fails on the first `Cluster`
object with `conversion webhook … dial tcp …:443: connect: connection refused`,
which reads as a networking fault rather than an ordering one. Keep it `false`;
step 2 satisfies it.

#### Why the installer seeds cert-sync immediately

cert-sync is a CronJob (`23 */6 * * *`). On a fresh install that would leave the
edge without its `ca-bundle`, its `loki-push-client-tls` and its
`s3-edge-credentials` for up to six hours — and none of the three is optional:
the s3-uploader mounts `ca-bundle` and reads its S3 key pair out of
`s3-edge-credentials` as environment variables, and Vector mounts `ca-bundle`
and `loki-push-client-tls`, so neither pod can start at all. Step 7 runs the
CronJob's own pod spec once via `kubectl create job --from=cronjob`, so it
cannot drift from what the schedule does later.

The S3 key pair is delivered rather than written on the edge for the same
reason the CA bundle is: it is one credential that would otherwise have to be
typed identically into two files — `<edge>-s3` here, which SeaweedFS builds the
edge's scoped identity from, and `s3-edge-credentials` there, which its uploader
authenticates with. A mismatch stalls the pipeline at upload with an S3 403 and
nothing says why, so the edge's own secrets file deliberately does not carry it.

---

## Configuration reference

Everything below lives in `sites/<site>/values.yaml`.

### Identity and addressing

```yaml
clusterLabel: mgmt              # label on this plane's own logs/metrics
installMode: fresh              # fresh | existing (adopting a running k0s)
topology: onprem                # onprem | cloud

domain:
  internal: aisedge.local       # internal DNS suffix; needs no real zone
  mgmtNodeIP: "203.0.113.10"    # what the edges dial

hostnames:                      # published on :443, routed by SNI
  seaweedfs: seaweedfs.aisedge.local
  grafana:   grafana.aisedge.local
  loki:      loki.aisedge.local
```

The **child-cluster hostnames are deliberately absent here.** They used to be
fleet-wide, which gave every edge the same `apiHost`, so a second site's Ingress
claimed a hostname the first already owned and the fleet could not exceed one
site. They are per-edge now, and the chart refuses to render if the old
fleet-wide keys reappear.

### Edges

One entry per site. Each produces a hosted control plane, an S3 bucket, a scoped
identity, an uploader and a reclaimer.

```yaml
edges:
  - name: edge-dev
    nodeIP: "203.0.113.20"
    join: ssh                       # ssh (default) | bundle — see below
    sshUser: ubuntu                 # join: ssh only — install.sh pushes the join
    sshKey: ~/.ssh/id_ed25519       #   over ssh. OMIT BOTH for join: bundle.
    s3SecretRef: edge-dev-s3
    exposure: sni                   # sni | nodePort — use sni
    # joinTokenTTL: 2h              # how long this edge's join token stays valid.
    #                               # Default 2h. The ssh path spends it in
    #                               # seconds; raise it only for a `join: bundle`
    #                               # edge whose bundle has to travel further than
    #                               # that. It is a BEARER credential — anything
    #                               # holding it can join a node — so a longer
    #                               # window is a deliberate decision.
    # apiHost / konnectivityHost default to <prefix>-<name>.<domain>
```

**`join: bundle` — for an edge this node cannot reach.** A hospital behind a
whitelisted-IP allowlist, a VPN or GlobalProtect has no inbound path, so the
default push-over-SSH join cannot run. With `join: bundle`, `install.sh` writes
a single self-contained `<edge>-join.sh` instead; you carry it to the site by
whatever route you have and run `sudo bash <edge>-join.sh` there, and the
installer waits for the node to appear. `sshUser`/`sshKey` are then unused.

Only the one-time bootstrap differs — once joined, both modes are identical,
because the edge dials *out* and nothing ever connects into the site. It is
**not** an offline mode: the edge still needs permanent outbound reachability to
this node on 443. Full walkthrough, guards and teardown caveat: `docs/TOUR.md`
§4.1.

**Use `exposure: sni`.** The control plane becomes a ClusterIP Service reached
through the ssl-passthrough Ingress on :443 — which is already how the worker
connects. Its ports are *Service* ports, which are per-Service, so **two sites
can never collide and you allocate nothing**. Adding a site needs no port
assignment at all.

`nodePort` additionally reserves those numbers cluster-wide, which is the only
reason a unique pair per site would be needed. Verified here: the worker dials
`<mgmtNodeIP>:443` and the ingress routes to the Service ClusterIP — nothing
dialled the node port from outside.

If you do use `nodePort`, the numbers are explicit on purpose: deriving them from
list position means inserting a site renumbers every site after it, and the
Service carries `resource-policy: keep`, so the change would silently fail to
apply.

> Migrating an existing site `nodePort` → `sni` works, with one manual step:
> k0smotron creates a new ClusterIP Service and leaves the old NodePort one
> behind holding the ports. Once the new Service has endpoints, delete it:
> `kubectl -n <edge> delete svc kmc-<edge>-nodeport`.

**Measured cost:** ~231Mi per uploader. On a 16Gi management node that is a
practical ceiling around **15 sites**.

### Edge-local configuration

`sites/<edge>/values.yaml` carries only what is genuinely local — the AE-title
map, the de-identification profile, and storage paths. Everything else is
**derived** from the management site file, which is passed to the edge release
as well:

| Derived | From |
|---|---|
| `upload.s3.endpoint` | `hostnames.seaweedfs` or `seaweedfs.<domain.internal>` |
| `upload.s3.bucket` | `<bucketPrefix>-<clusterLabel>` when `perSiteBuckets` |
| `observability.loki.endpoint` | `hostnames.loki` or `loki.<domain.internal>` |
| `hostAliases` | `domain.mgmtNodeIP` + the hostnames edge pods actually dial |

Each of those used to be typed a second time, and **every mismatch in that group
fails silently** — the uploader retries an endpoint that will never answer,
correctly preserves its local copy, and the management side, which watches for
arrivals rather than absences, reports nothing wrong.

### De-identification

```yaml
orthanc:
  aet: AISEDGE
  deid:
    enabled: true
    existingSaltSecret: orthanc-deid-salt
    aetMap:
      AISEDGE: {project: my_project}
    profile:
      DeidMode: modify
      RemovePrivateTags: false
      Keep: [StudyInstanceUID, SeriesInstanceUID, SOPInstanceUID, FrameOfReferenceUID]
      Replace:
        PatientIdentityRemoved: 'YES'
        PatientName: ANONYMOUS
        PatientID: ${ProjectCode}-${SubjectHash}
```

* **`deid.policyReviewed` has no default.** The chart refuses to render until a
  human asserts they have read the profile and the AE-title map for this site. It
  lives at the top level next to `deid.engine`, not under `orthanc:`, because it
  gates every engine and not just the Lua one.
* **UIDs are retained** so a study stays internally consistent across series.
* **An unmapped AE title is quarantined, not dropped** — see
  `dataPolicy.originals.quarantine`.
* **The HMAC salt must survive reinstalls.** The same patient hashed with a
  different salt becomes a different pseudonym, so rotating it splits one
  subject into two in XNAT.

---

## Secrets

The charts never contain credentials. They reference Secrets by name, and those
Secrets are created separately from a SOPS-encrypted file.

```bash
scripts/site-secrets.sh new <site> <mgmt|edge>       # scaffold; the ROLE is required
scripts/site-secrets.sh add-edge <mgmt-site> <edge>  # scaffold an edge AND mint its S3 key pair
scripts/site-secrets.sh encrypt <site>               # before committing
scripts/site-secrets.sh edit <site>                  # decrypt → $EDITOR → re-encrypt
scripts/site-secrets.sh view <site>                  # print decrypted (careful: terminal)
scripts/site-secrets.sh apply <site>                 # decrypt straight into the cluster
scripts/site-secrets.sh check                        # fail if any committed secret is plaintext
```

**`new` does not guess the role.** An edge scaffolded from the management
template renders perfectly — Helm ignores values a chart does not declare — and
then silently overrides the fleet's `dataPolicy` from the wrong file; a
management site scaffolded from the edge template is missing every hostname the
edges derive their endpoints from. Both fail much later and in the least obvious
way, so the argument is mandatory rather than defaulted.

**Use `add-edge` to onboard an edge**, not `new … edge`. It scaffolds
`sites/<edge>/`, mints the edge's S3 key pair once, and writes it into the
management secrets file as `<edge>-s3` — the one credential that still has to
exist in two places, and the last one a human could mismatch by hand. It
deliberately does **not** edit the management `values.yaml`: that file is the
most heavily annotated in the repo and a YAML round-trip would destroy every
caution comment in it, so it prints the `edges:` block for you to paste, along
with the steps it cannot do for you.

`apply` pipes the plaintext directly into `kubectl` — it never touches disk. It
also creates any namespace its Secrets name, which is what makes
**secrets-before-workloads** possible on a bare cluster.

Only `data` and `stringData` are encrypted. Names, namespaces and keys stay
readable, so `git diff` shows *which* credential changed without showing it, and
tooling can read structure without decrypting.

### Namespaces are part of the contract

A Secret is only readable from its own namespace, and for this chart nearly
everything — SeaweedFS, Loki, Grafana, Alertmanager — runs in the **release**
namespace. Only the uploader/reclaimer run in `xnat-upload`. Getting this wrong
installs cleanly and leaves pods in `CreateContainerConfigError` with nothing in
the chart to tell you why, so `make secret-contract` checks it.

---

## Data policy — what is kept and for how long

One block governs every store, and it is passed to **both** charts so a site has
exactly one answer.

```yaml
dataPolicy:
  enabled: false      # nothing expires until you turn this on
  dryRun: true        # decisions are logged, never acted on

  originals:                                   # the archive of record
    allowExpiry: false  # the THIRD switch — while false the facility-backup
                        # volume is mounted read-only and no original is removed
    facilityBackup: {retain: forever, minFreeDiskPercent: 10}
    quarantine:     {retain: forever, alertAfter: 24h}
    fileDrop:       {reclaim: never,  minAge: 30d}

  derived:                                     # reproducible from the originals
    orthancStorage: {reclaim: onGrouped,       minAge: 7d}
    grouped:        {reclaim: onAssigned}      # no minAge: assign unlinks at
                                               #   assign time, so only orphans
                                               #   reach the engine; setting it
                                               #   is rejected at render
    assigned:       {reclaim: onUploaded,      minAge: 0}
    s3Staged:       {reclaim: onXnatConfirmed, minAge: 1d,
                     verifyAgainstXnat: true, maxRemovals: 50,
                     schedule: "17 * * * *"}
    # upload.mode: direct only. NOT a stage of its own: it is the delete
    # authority for whichever tree above is TERMINAL under the chosen deid
    # engine (/data/assigned under Orthanc-deid, /data/deidentified under
    # ais-deid). Under upload.mode: s3 it does not render at all, because the
    # s3-uploader's marker already answers the same question there.
    stagedReclaimer: {minAge: 1d, verifyAgainstXnat: true,
                      maxRemovals: 50, schedule: "17 * * * *",
                      deadlineSeconds: 3000}

  telemetry:
    # the kubelet rotates by size x count, not by time. 10Mi x 5 = 50Mi
    # of on-disk log per container.
    podLogFiles: {maxSize: 10Mi, maxFiles: 5}
```

**Loki and Prometheus retention are not set here.** Helm cannot template a
subchart's values from the parent, so keys under `telemetry` for them would read
exactly like policy and do nothing — an operator could edit them, see a clean
install, and keep the old retention indefinitely with nothing to say so. Setting
`telemetry.loki` or `telemetry.prometheus` is now **rejected at render time**.
Set retention where it is actually read, in the same `sites/<site>/values.yaml`:
`kube-prometheus-stack.prometheus.prometheusSpec.retention` for Prometheus and
`loki.loki.limits_config.retention_period` for Loki. `podLogFiles` is likewise
not a duration — the kubelet rotates container logs by size and count only, so a
window it could never honour was unimplementable rather than merely unwired. It
is applied as `--kubelet-extra-args` at **worker-join time**, on both join paths,
so changing it affects workers joined afterwards; an already-joined node needs its
k0s worker service reinstalled, and `make verify-live` fails on the mismatch
rather than letting the edit look applied.

Three properties worth understanding:

**Every derived rule is `(condition AND minAge)` — both must hold.** A pure age
rule would expire a session that never reached XNAT because a credential was
wrong. A pure condition rule frees nothing once the signal breaks.

**`onXnatConfirmed` verifies content, not existence.** XNAT creates the
experiment on the first resource POST, so "the experiment exists" is true even
for a partial upload. The reclaimer sums every `__MANIFEST__.json` into a set of
`filename → MD5`, lists what XNAT actually holds, and deletes only when
`missing == 0 AND mismatched == 0`. Every uncertainty — an unreadable manifest,
a 500 from XNAT, an unparseable listing — resolves to **keep**.

**`maxRemovals` bounds a bug.** A run that decided "delete everything" is capped
per run, leaving the rest for somebody to notice. At the hourly schedule this
still drains ~1200 sessions/day.

**A fresh install expires nothing.** Run with `dryRun` for a week and read the
decisions it logs before enabling it.

**Originals need a third switch.** `enabled` and `not dryRun` arm the *derived*
stages only. A duration on `originals.facilityBackup` or `originals.quarantine`
does nothing until `dataPolicy.originals.allowExpiry` is also true — the
`edge-data-policy` DaemonSet logs `expiry_skipped` instead, and the chart keeps
the facility-backup volume mounted read-only, so the kernel refuses the delete
even if the engine were wrong. Deleting an original destroys the only
identifiable copy, so it takes its own deliberate act on top of the other two.
Full truth table: `docs/TOUR.md` §5c.

---

## Security model

| Boundary | Mechanism |
|---|---|
| Hospital → management | Outbound TLS only. No inbound route to the edge. |
| Between edge sites | **One S3 bucket per site.** SeaweedFS matches identity actions as `<action>:<bucket>` with **no prefix scoping**, so a shared bucket would let any edge key read and delete every other site's staged imaging. The bucket is the only boundary there is. |
| Edge → XNAT | The edge has **no XNAT credential**. Only the management uploader does. This is the main operational advantage of `upload.mode: s3`. |
| S3 ingestion | Per-edge **SigV4 key pair**, scoped to that site's bucket (the row above). Optionally a second factor: `seaweedfs.ingress.clientCerts` adds a per-edge **client certificate**, verified at the SeaweedFS Ingress with the same `auth-tls-*` annotations the Loki path uses — the key pair is a bearer secret usable from anywhere, the certificate is a private key that never leaves the site and rotates every 90 days. **Ships off**, and turning it on is a four-step rollout (`issue` → confirm `s3-client-tls` landed → edge `requireClientCert` → `require`): flipping verification on before the certificates arrive breaks every upload with an error that names nothing — measured, the handshake succeeds, nginx answers HTTP 400, and rclone reports it as an S3 XML parse failure, so it reads as a dead endpoint. See `docs/components/seaweedfs.md`. |
| Loki ingestion | Per-edge **client certificate (mTLS)**, verified at the Ingress (`auth-tls-verify-client: on`, with `auth-tls-match-cn` pinned to the names in `edges`). cert-manager issues one `<edge>-loki-client` certificate per site and cert-sync delivers it as `loki-push-client-tls`. Loki itself runs `auth_enabled: false`, so the Ingress is the only place it is checked. The CN pin admits every site on the one push hostname, so it bounds *which* certificates are accepted, not one edge writing under another's name. |
| TLS | Internal CA via cert-manager. An https S3 endpoint with no CA bundle is **refused at render time** — an empty `AWS_CA_BUNDLE` silently disables verification rather than falling back to the system store. |
| Credentials at rest | SOPS + age. Never in a values file, never in a ConfigMap, never in git. |
| CA private key | `tls.key` can never be copied to an edge — cert-sync refuses to render it. |

`install.sh` also **refuses to install** if `sites/<site>/secrets.enc.yaml` is
not SOPS-encrypted, or — when `sops` is on `PATH` — if any *value* in it is
still an unfilled `REPLACE_` placeholder. It decrypts to a pipe, never to disk,
and checks the values rather than the file text: the templates' own comments say
"fill in every REPLACE_", so grepping the whole file refused to install a
complete, correct site. Note the two limits of that check: `sops` is not in the
required-tools list, so on a node without it the placeholder check is skipped
entirely, and **nothing anywhere enforces a minimum length or strength** on a
credential you did fill in. The check exists because the template once shipped
working defaults annotated "change defaults", and the first deployment ran with
them unchanged — a comment is advice, and advice does not fail an install.

---

## Observability and alerting

Prometheus scrapes the management plane. Loki receives logs from every edge via
Vector. Alerts come from **two** sources:

* **Prometheus rules** — resource and certificate conditions.
* **Loki ruler rules** — pipeline conditions, derived from the JSON log events
  the pipeline emits. These live in the ruler rather than Prometheus because the
  management Prometheus cannot scrape edge pods across the one-way konnectivity
  tunnel, and because the source of truth is the log event, not a derived metric.

The uploader's log schema is a **public interface**. `upload_started`,
`upload_completed` and `upload_failed` are matched by three Loki ruler alert
rules — `XNATUploadFailingForAllSessions`, `S3UploaderRetryStorm` and
`SessionUploadStalled`, five event matchers between them in
`charts/mgmt/files/loki-ruler-rules.yaml` — and by eight Grafana dashboard
panels; renaming one disables the corresponding alert silently.

```bash
# Does every alert actually have the metrics it depends on?
scripts/check-alert-inputs.sh
```

That script asks the **live** Prometheus whether each alert's inputs have any
series at all. It is how three alerts were found that had never been able to
fire — including certificate expiry, on a fleet where every edge validates
against a CA that must be rotated in two phases weeks apart.

---

## Repository structure

```
install.sh                     the only entrypoint
Makefile                       CI entrypoint (make ci-fast / make ci), and
                               make verify-live SITE=<site>, which is NOT CI
sites/
  example-mgmt/                template for THE management node (one per deployment)
  example-edge/                template for ONE edge node (one per facility)
  <site>/values.yaml           SINGLE SOURCE OF TRUTH for a deployment. The
                               management file is passed to BOTH charts, so
                               anything shared is written here exactly once;
                               each edge file is passed after it and carries
                               only what is local to that site.
  <site>/secrets.enc.yaml      SOPS-encrypted; charts reference these by name
charts/
  mgmt/                        management chart
    templates/                 seaweedfs, xnat-upload, observability,
                               cert-issuers, cert-sync, edge-clusters
    files/                     reclaim-staged.sh, cert-sync.sh, ruler rules
  edge/                        edge chart
    templates/                 orthanc, ingest-pipeline, upload, vector, storage
    files/                     s3-uploader.sh, deidentify-and-forward.lua,
                               vector.yaml
scripts/
  site-secrets.sh              create / encrypt / apply site secrets
  verify-live.sh               read-only checks against a RUNNING deployment
  uninstall.sh                 full reset
  01,05,06,06b,06c             bootstrap steps Helm cannot do — 06 joins over
                               SSH, 06b builds the carry-over bundle for an edge
                               with no inbound path, 06c is the post-join work
                               both paths share
  files/edge-join.sh           the join itself; runs ON the edge, identical for
                               both paths
  adopt-existing.sh            take over a running imperative install
  rotate-ca.sh                 two-phase CA rotation across the fleet
  clear-staged-s3.sh           clear the S3 staging prefix; empty session
                               prefixes only, unless you pass --all
  check-alert-inputs.sh        ask live Prometheus whether alerts can fire
  ci/                          CI stages (render, negative, promtool, …), one
                               script per stage, invoked by the Makefile
tests/
  reclaimer/                   45 cases asserting on what was DELETED, both backends
  loki-rules/                  the real Loki rule expressions, against fixture
                               logs, evaluated by the pinned Loki
  data-policy/                 the real engine under the real image, asserting
                               on what SURVIVED
config/k0s-controller.yaml     the management k0s controller config (scripts/01)
manifests/01-management/       the k0smotron Cluster template rendered by
                               scripts/05, one per edge
docs/                          component guides, CA ceremony, alerting design
```

---

## Continuous integration

```bash
make ci-fast     # no cluster, no docker
make ci          # adds the three docker-based stages: loki-rules, data-policy,
                 # greenfield

make verify-live SITE=<site>   # NOT CI — read-only checks against a RUNNING
                               # deployment. See "Then verify, every time".
```

| Stage | Proves |
|---|---|
| `render` | both charts render across 40 value combinations |
| `negative` | 57 render-time guards each fire on the condition they claim to detect, plus a census that fails if a guard is added without a case |
| `promtool` | 16 alert-rule unit tests — each rule fires on the condition it describes |
| `shell-syntax` | every script parses; no `yes \|` pipeline under `pipefail` |
| `pvc-retention` | nothing holding data can be auto-deleted |
| `runtime-templates` | scripts survive Helm rendering |
| `duplicate-names` | no two objects collide |
| `reclaimer` | 45 cases, asserting on **what was deleted**, not on log text. 34 drive the S3 backend through stub `aws`/`curl` binaries; 11 drive the filesystem backend against a real directory tree, where the assertion is that the session directory is gone |
| `secret-contract` | every mounted Secret exists, in the right namespace, with the right keys |
| `values-consumers` | every values key that declares a behaviour has something reading it — Helm never warns about a value nobody consumes |
| `loki-rules` | the real Loki ruler expressions, evaluated against fixture logs by the pinned Loki — promtool covers only the Prometheus rules |
| `data-policy` | the edge retention engine, run under the real busybox image the chart deploys, asserting on **what survived** |
| `greenfield` | the charts install onto an empty cluster |

The last three need docker. They **skip loudly** without it, and the skip is
reported separately from a pass, so a docker-less run never reads as "the charts
are installable". `CI_REQUIRE_LOKI_TESTS`, `CI_REQUIRE_DATAPOLICY_TESTS` and
`CI_REQUIRE_GREENFIELD` turn each skip into a failure, which is what the GitHub
workflow sets.

Two of these exist because of specific classes of silent failure:

**The reclaimer is the only component that deletes patient data**, so it is
tested by asserting on the deletes. A run that logs `reclaim_kept` and issues a
DELETE anyway would pass a log-only test and fail this one. Its `aws` and `curl`
are stubbed and **fail by default** for anything a case does not configure — a
stub that invented a plausible success would test the opposite of the property
that matters.

**`secret-contract`** renders both charts and fails if any mounted Secret is
absent, in the wrong namespace, or missing a key. A wrong namespace and a
missing key fail identically and silently at runtime: helm reports success and
the pod sits in `CreateContainerConfigError`.

---

## Operating

### Health

Start with `make verify-live SITE=<site>` — it reads the site file and checks
the whole fleet in one pass, so the one-liners below are for when it has told
you *where* to look, or when you want a number it does not report.

```bash
helm list -A
kubectl get pods -A
kubectl --kubeconfig kubeconfig-<edge> get pods -A

# S3 buckets and sizes
kubectl -n ais-mgmt exec deploy/mgmt-seaweedfs -c seaweedfs -- \
  sh -c 'echo "s3.bucket.list" | weed shell -master=localhost:9333'

# certificates
kubectl get clusterissuer
kubectl -n cert-manager get certificate
```

### Send a test study

```bash
dcmsend <orthanc-pod-ip> 4242 -aec AISEDGE study.dcm
```

Then follow it: Orthanc logs (`Lua says: {"backupPath": …}`) →
`/data/facility-backup` → study labelled `xnat-ingest-ready` → `/data/grouped` →
`/data/assigned` → `upload_completed` in the s3-uploader log →
`s3://ingest-<edge>/staged/` → the management uploader log.

Note that **re-sending the same file produces no upload notification**. DICOM
UIDs are deterministic, so Orthanc deduplicates it into a study already labelled
`xnat-ingest-processed`, and the uploader reports
`Skipping upload … as all the resources already exist on XNAT`. That is correct
idempotence, not a failure. Use a different study to test a fresh write.

### Adding an edge

An `edges:` entry alone is not enough — the new site also needs its own
`sites/<edge>/` directory and an S3 key pair. Without them `install.sh` dies at
step 7/7 with `missing sites/<edge>/values.yaml`, *after* the hosted control
plane is up and the worker has joined, which is the expensive half.

```bash
# 1. scaffold sites/<edge>/ and generate its S3 key pair into the management
#    secrets file as <edge>-s3 (cert-sync delivers it to the edge as
#    s3-edge-credentials; do not write it on the edge side). Prints the
#    'edges:' block to paste.
scripts/site-secrets.sh add-edge <site> <edge>

# 2. the AE-title map, de-identification profile and disk paths — facts only
#    you have, so nothing generates them
$EDITOR sites/<edge>/values.yaml

# 3. the de-identification salt. The template ships
#    AIS_DEID_HMAC_SALT: REPLACE_64_HEX_CHARS, and it is deliberately NOT
#    auto-generated: it must survive reinstalls, and silently regenerating it
#    would re-pseudonymise every existing patient.
openssl rand -hex 32
$EDITOR sites/<edge>/secrets.enc.yaml

# 4. paste the printed block under 'edges:'. s3SecretRef must be <edge>-s3 —
#    cert-sync substitutes <edge> and nothing else, and the chart refuses to
#    render if the two disagree.
$EDITOR sites/<site>/values.yaml

# 5. encrypt the new edge before committing (add-edge already re-sealed the
#    management file if it was encrypted)
scripts/site-secrets.sh encrypt <edge>

# 6. install, then prove it
./install.sh <site>
make verify-live SITE=<site>
```

Existing sites are untouched; the new one gets its own control plane, bucket,
identity, uploader and reclaimer. Full walkthrough: `docs/TOUR.md` §5b.

### Removing an edge

Remove its entry from `edges:`, then `helm upgrade`. Reset the worker with
`k0s reset` on the edge machine. The staged data and the SeaweedFS identity are
removed with the entry.

### CA rotation

Two phases, weeks apart — see `docs/ca-ceremony.md`. cert-sync distributes the
new bundle to every edge on its schedule, so rotation does not require visiting
each site. `CertificateExpiringSoon` fires at 60 days.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Edge pods `CreateContainerConfigError` | A Secret is missing. Most often `ca-bundle`, `loki-push-client-tls` or `s3-edge-credentials`, all three delivered by cert-sync — run its job manually: `kubectl -n ais-mgmt create job x --from=cronjob/mgmt-cert-sync-<edge>` |
| `helm install` fails with `conversion webhook … connection refused` | The k0smotron operator is not ready. It needs cert-manager, which must be installed *before* the chart. |
| `invalid ownership metadata` on install | An object exists without Helm's ownership labels, usually from a previous non-Helm install. `scripts/uninstall.sh` clears these. |
| Worker join times out | On a `join: bundle` edge, first check the obvious one: the bundle has not been run on the edge yet — the installer is waiting for the node to appear and 06c says so on timeout. Otherwise the management node cannot resolve its own child-cluster API: check `/etc/hosts` has the `aisedge` entries — a partial teardown that removed the entries but left the marker comment causes the installer to skip re-adding them. |
| Uploader retries forever, no error on the management side | The edge cannot reach the S3 endpoint. Check `hostAliases` resolve and the CA bundle is present. The edge correctly preserves its local copy, so the only symptom is an absence. |
| `XNATAuthFailure` while uploads succeed | Was a false positive from `xnat-ingest` progress-bar output matching bare `401`/`403`. Fixed; the rule now requires HTTP context and drops `it/s` lines. |
| Loki logs `NoSuchBucket` at startup | Non-fatal. The bucket-creation hook is `post-install`, so Loki retries its chunk store until the bucket appears. It converges without restarting. |

---

## Orthanc REST API Authentication

The shipped edge site sets `orthanc.auth.enabled: false`. Orthanc's REST API is
`ClusterIP`-only, so nothing outside the cluster can reach it — but that is an
accident of network placement, not a control. Anything running *inside* the
cluster can call that API, and it can **delete studies**. Turn it on for any
deployment where that matters.

Three keys, all required, because two different things read this Secret:

| Key | Read by | If it is wrong |
| --- | --- | --- |
| `users.json` | Orthanc itself, via `RegisteredUsersFile` | Orthanc fails to start — the file its config points at was never mounted |
| `orthanc-user` | `group-orthanc`, calling the REST API | Orthanc answers 401 and the pipeline stalls with data sitting in Orthanc |
| `orthanc-password` | `group-orthanc` | as above |

`orthanc-user` / `orthanc-password` **must match** the user and password inside
`users.json`. They are separate keys because Orthanc wants a file and
`group-orthanc` wants environment variables; nothing reconciles them for you.

**1. Generate a password and add the Secret.**

```bash
openssl rand -base64 24                       # use this as <password> below
scripts/site-secrets.sh edit <site>           # decrypts to $EDITOR, re-encrypts on save
```

Add this document (the template is already in your `secrets.enc.yaml`, commented
out — uncomment and fill it in):

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: orthanc-credentials
  namespace: xnat-ingest          # the EDGE site's namespace
type: Opaque
stringData:
  users.json: '{"RegisteredUsers":{"admin":"<password>"}}'
  orthanc-user: admin
  orthanc-password: <password>
```

The password is **plaintext inside that JSON** — Orthanc has no hashed-password
format here. That is precisely why this file is SOPS-encrypted before it is
committed, and why `scripts/site-secrets.sh check` refuses a plaintext one.

**2. Turn it on in the site file.**

```yaml
orthanc:
  auth:
    enabled: true
    existingSecret: orthanc-credentials
```

The chart refuses to render if `enabled: true` and `existingSecret` is empty —
the deployment mounts that Secret non-optionally, so an empty name would fail
as a confusing volume error rather than an auth one.

**3. Apply, and restart what reads it.**

```bash
scripts/site-secrets.sh apply <site>
./install.sh <site>
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest rollout restart deploy/<release>-orthanc
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest rollout restart deploy/<release>-group-orthanc
```

Both restarts are needed: Kubernetes does not restart a pod when a Secret
changes, and neither Orthanc nor `group-orthanc` re-reads one at runtime.

**4. Verify.**

```bash
# from inside the cluster — should now be 401 without credentials
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest exec deploy/<release>-orthanc -- \
    curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8042/studies
# and 200 with them
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest exec deploy/<release>-orthanc -- \
    curl -s -o /dev/null -w '%{http_code}\n' -u admin:<password> http://localhost:8042/studies
```

Then confirm the pipeline still moves: `group-orthanc`'s log should keep
reporting `Found N studies`, not 401s. If it 401s, `orthanc-user` /
`orthanc-password` disagree with `users.json`.

> **Do not expose port 8042 to the host or a NodePort just because auth is now
> on.** `orthanc.expose.http` stays `ClusterIP`. Authentication is a second
> layer here, not a replacement for keeping the API off the network.

## Uninstall

```bash
scripts/uninstall.sh <site>                  # full reset, both nodes
scripts/uninstall.sh --keep-cluster <site>   # workloads only, keep k0s running
```

The default is a genuine clean slate: both Helm releases, all namespaces, the
CRDs and admission webhooks, cluster-scoped RBAC (including the Roles these
components leave in `kube-system`), every PersistentVolume **and its host
directory**, `/data` on every node, `/etc/hosts` entries **and their marker
comments**, the generated kubeconfigs and join tokens, and `k0s reset` on the
management node and each edge.

**One exception, and it is loud: a `join: bundle` edge.** The remote half of a
teardown runs over SSH, and a bundle site has no inbound path by definition. The
script detects that — `join: bundle`, or an empty `sshUser` — warns that **the
edge half is not done**, and prints the commands to run on the edge itself:
`k0s stop`, `k0s reset`, the `/data`, `/var/lib/k0s`, `/etc/k0s` and
`/var/lib/vector` wipe, the `/etc/hosts` line, and a reboot to clear CNI
interfaces and iptables state. That check exists because the old condition only
required `sshUser` to be non-empty — which a bundle site legitimately leaves out
— so it skipped in silence and "full reset" reported success with k0s still
running and `/data` intact on the machine.

It requires you to type the site name, because it deletes `/data` — which holds
the facility backup, the archive of record.

**It never deletes your age key or your site files.**

A partial teardown is worse than none. A CRD without its operator, a namespace
Helm cannot adopt, cert-manager RBAC from a release that no longer exists, or a
stale `/etc/hosts` entry each make the *next* install fail in a way that looks
like a bug in the charts.

---

## Pinned versions

| Component | Version |
|---|---|
| k0s / k0smotron | `v1.35.2+k0s.0` / `v2.0.3` |
| cert-manager | `v1.20.3` |
| kube-prometheus-stack | `87.19.2` |
| Loki | `7.1.0` (app 3.6.8) |
| Vector | `0.57.0` |
| ingress-nginx | `4.15.1` |
| Orthanc | `1.12.11` |
| xnat-ingest | `0.15.0` |

Every one is what is **verified working**, read out of a live deployment rather
than chosen from a changelog. The previous installer used `/latest/` and
`/stable/` URLs, so a rebuild months apart got whatever upstream had published
that morning. Upgrade them deliberately, one at a time.

### Requirements

* Ubuntu 22.04 on the management node and each edge
* Key-based SSH from the management node to each edge — **only for `join: ssh`,
  the default**. A site with no inbound path uses `join: bundle` and needs no
  SSH at all (see **Edges** above, and `docs/TOUR.md` §4.1). Teardown of a
  `join: bundle` site then has to be finished by hand on the edge.
* `sops` and `age` on the management node
* Ports: **443** inbound on the management node; **4242** (DICOM) on each edge
  from its modalities; **22** inbound on each edge from the management node
  **for `join: ssh` only**. In steady state — and always under `join: bundle` —
  the edge only dials *out*, to the management node on 443, under either
  `exposure` mode.
* ~16Gi RAM on the management node supports roughly 15 edge sites

## Stanford deployment

Stanford/rsl60 now uses the consolidated Helm charts with site values in
[`sites/stanford/`](sites/stanford/values.yaml) and
[`sites/edge-rsl60/`](sites/edge-rsl60/values.yaml). The chart stages preserve
external Orthanc ingestion, PatientID routing, Samba uploads, automatic XNAT
project ownership, token refresh, and verified S3 archival. Follow the
[rsl60 deployment runbook](docs/rsl60-existing-orthanc-deployment.md) to configure
and adopt the existing deployment.
