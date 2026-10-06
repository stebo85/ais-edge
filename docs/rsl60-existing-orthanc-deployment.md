# Stanford/rsl60 deployment with the Helm charts

Stanford now uses `charts/mgmt` and `charts/edge`, configured by
`sites/stanford/values.yaml` and `sites/edge-rsl60/values.yaml`. The pipeline
uses upstream `xnat-ingest:0.15.6`; the old fork's routing and project
provisioning are chart-mounted Python stages.

The Stanford values retain the existing Orthanc store under `/local/orthanc/db-v6`,
Samba shares under `/local/samba/public/`, staging bucket `ingest-bucket`,
control-plane NodePorts 30443/30132, and worker runtime under `/data/k0s`.
Addresses and credentials remain placeholders; fill them from the existing
configuration before installing. Preserve the existing S3 keys and CA when
adopting a running deployment.

## Configure and review

1. Edit `sites/stanford/values.yaml`: management/edge IPs, domain/hostnames,
   SMTP settings, and the existing cluster exposure. `edges[].join: bundle`
   uses the upstream carry-over bootstrap without SSH into rsl60.
2. Edit `sites/edge-rsl60/values.yaml`: external Orthanc URL and the relevant
   storage/share paths. Authentication comes from the `orthanc-credentials`
   Secret, with `orthanc-user` and `orthanc-password`; leave credentials out of
   URLs and values files. Set `orthanc.auth.enabled: false` if the existing API
   does not require authentication.
3. Copy each site's `secrets.example.yaml` to `secrets.enc.yaml`, fill its
   placeholders, then encrypt with `scripts/site-secrets.sh encrypt <site>`.
   Management credentials and edge credentials go to their respective clusters.
   The `xnat-token-source` Secret holds long-lived credentials that can issue
   aliases and manage XNAT projects. `xnat-credentials` is the upload token
   target and must already exist before the refresh job patches it.
4. Review the existing-resource adoption process in
   [`scripts/adopt-existing.sh`](../scripts/adopt-existing.sh). The chart introduces release-owned
   workload names. Stop the old `xnat-ingest-sort` and `xnat-ingest-upload`
   workloads before enabling their replacements, so two pipelines do not read
   the same Orthanc or bucket concurrently. Preserve queued data and storage.

Stanford receives DICOM data de-identified upstream, so its values select
`deid.engine: none`. The external receiver and its storage are kept outside
Helm; no managed Orthanc pod, DICOM port binding, salt, or Lua de-identification
hook is installed. Keep Orthanc storage and the pipeline on the same filesystem.
Prepare both Samba host directories on rsl60 before installation; their mounts
require existing directories rather than silently creating a mistyped path.

## Routing and file pickup

`PatientID=subject@group/project` routes to `project.subject.visit`, carrying
`SourceGroup=group` for ownership. The visit comes from the first nonempty
`AccessionNumber`, `StudyID`, or `StudyInstanceUID`. Other studies go to the
configured `fallbackProject` (`misc`). Stable unlabeled studies are admitted
in bounded batches; ready/processed labels remain `xnat-ingest-ready` and
`xnat-ingest-skip`.

Raw data uses `<group>/<project>/<subject>/`, for example
`polimeni/openrecon/test/`. After the quiet period it becomes
`openrecon.test.samba_upload/1.SambaUpload/FILES/`, with modern
`__METADATA__.json` and `__MANIFEST__.json`. Pickup retains the group/project
folders and copies the originals to the `xnat-upload-done` archive before
publishing the session. Interrupted claimed sources are restored for retry.

An empty raw `allowedProjects` list admits every project independently of the
DICOM list. A nonempty list is extended by projects observed on the routed
DICOM path. Empty folders do not trigger staging or project creation.
`PhoenixZIPReport` DICOM resources are excluded from the assigned copy; the
external Orthanc original remains available.

The per-edge management uploader has a project-provisioner sidecar. It creates
projects for settled sessions, assigns the existing `SourceGroup` user as Owner,
and verifies membership. Unknown users are logged as deferred; no accounts are
created. `brosnan` and `sciget` are synchronized as Owners across existing and
new projects. Alias credentials refresh every 12 hours and the job rolls the
per-edge uploaders; `install.sh` runs the first refresh immediately.

## Upload and archival

The edge uses upstream's rclone uploader with two transfers and an 80 MiB/s
bandwidth limit. Management waits 300 seconds for S3 writes to settle.
The verified reclaimer checks XNAT delivery, then copies the session to
`uploaded/<UTC timestamp>/<session>/`. It compares archive paths and byte sizes,
and confirms that the staged object listing did not change during copying,
before removing staging through the filer. A failed copy or verification keeps
the staged source. Existing upstream dry-run, age, and removal limits still apply.
The raw share and its archive are reported as original stages with permanent
retention; Orthanc store reclamation is disabled for this site.

## Install and check

With kubectl pointed at the existing management cluster:

```bash
./install.sh stanford
```

Carry `edge-rsl60-join.sh` to rsl60 when prompted and run it there. Existing
joined workers are retained. `workerDataDir` is an install-time choice; changing
it does not relocate a running worker's runtime. For an explicit runtime reset,
the existing reset script accepts `EDGE_K0S_DATA_DIR=/data/k0s`; review its dry
run before using its execution flag.

Render without applying:

```bash
helm template mgmt charts/mgmt -n ais-mgmt -f sites/stanford/values.yaml
helm template edge charts/edge -n xnat-ingest \
  -f sites/stanford/values.yaml -f sites/edge-rsl60/values.yaml
make stanford
```

Runtime checks:

```bash
KUBECONFIG=kubeconfig-edge-rsl60 kubectl -n xnat-ingest logs deploy/edge-stanford-ingest
KUBECONFIG=kubeconfig-edge-rsl60 kubectl -n xnat-ingest logs deploy/edge-s3-uploader
kubectl -n xnat-upload logs deploy/mgmt-upload-edge-rsl60 -c project-provisioner
kubectl -n xnat-upload logs deploy/mgmt-upload-edge-rsl60 -c upload
```

The local regression tests exercise routing, quiet periods, folder retention,
archive failure recovery, Owner verification, and copy-before-delete behavior.
The runtime test uses the pinned image to prove that real session loading and
assignment accept the migrated metadata; it can also run through
`XNAT_RUNTIME_PYTHON` pointing at a release-0.15.6 virtual environment.
