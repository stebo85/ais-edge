apiVersion: v1
kind: Namespace
metadata:
  name: xnat-ingest
---
# S3 credentials for the edge node — scoped to write+list on the ingest bucket only.
# These are the credentials defined for this CLUSTER_NAME in edge-nodes.env.
# Loss of this key cannot read XNAT data, cannot read other sites' data, and
# cannot bypass the bucket-level scoping enforced by SeaweedFS.
apiVersion: v1
kind: Secret
metadata:
  name: s3-edge-credentials
  namespace: xnat-ingest
type: Opaque
stringData:
  access-key: "{{S3_EDGE_ACCESS_KEY}}"
  secret-key: "{{S3_EDGE_SECRET_KEY}}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: xnat-ingest-sort-wrapper
  namespace: xnat-ingest
data:
  sort-wrapper.sh: |
    #!/bin/sh
    set -eu

    loop_seconds="${INGEST_LOOP_SECONDS:-60}"
    build_root="/data/staging/__build__"
    sort_output="${build_root}/sort-output"

    mkdir -p "${build_root}" /data/staging/__invalid__

    while true; do
      start_ts=$(date +%s)
      if [ -d "${sort_output}" ]; then
        python3 /opt/ais-edge-sort-wrapper/route-staged-sessions.py \
          "${sort_output}" /data/staging || true
      fi
      rm -rf "${sort_output}"
      mkdir -p "${sort_output}"

      python3 /opt/ais-edge-sort-wrapper/auto-label-studies.py "$@" || \
        echo "auto-label pre-pass failed; continuing with already-ready studies only" >&2

      if xnat-ingest sort "${sort_output}" "$@"; then
        python3 /opt/ais-edge-sort-wrapper/route-staged-sessions.py \
          "${sort_output}" /data/staging
      else
        echo "xnat-ingest sort failed; routing complete sessions and quarantining incomplete output" >&2
        python3 /opt/ais-edge-sort-wrapper/route-staged-sessions.py \
          "${sort_output}" /data/staging || true
      fi

      elapsed=$(( $(date +%s) - start_ts ))
      sleep_for=$(( loop_seconds - elapsed ))
      [ "${sleep_for}" -gt 0 ] || sleep_for=0
      echo "xnat-ingest sort loop took ${elapsed}s, sleeping ${sleep_for}s"
      sleep "${sleep_for}"
    done
  auto-label-studies.py: |
    import datetime
    import json
    import os
    import re
    import sys
    import urllib.parse

    import requests

    enabled = os.environ.get("AIS_EDGE_AUTO_IMPORT_UNLABELED", "").lower() in {
        "1",
        "true",
        "yes",
        "on",
    }
    if not enabled:
        sys.exit(0)

    argv = sys.argv[1:]

    def option(name, default=None):
        for index, value in enumerate(argv):
            if value == name and index + 1 < len(argv):
                return argv[index + 1]
        return default

    orthanc_url = option("--orthanc-url")
    ready_label = option("--orthanc-label", "xnat-ingest-ready")
    skip_label = option("--orthanc-skip-label", "xnat-ingest-skip")

    if not orthanc_url or not ready_label:
        sys.exit(0)

    route_field = os.environ.get("AIS_EDGE_PATIENTID_ROUTING_FIELD", "PatientID")
    require_route_match = os.environ.get(
        "AIS_EDGE_AUTO_IMPORT_REQUIRE_ROUTING_MATCH", "0"
    ).lower() in {"1", "true", "yes", "on"}
    fallback_project = option("--project-id", "misc")
    batch_size = int(os.environ.get("AIS_EDGE_AUTO_IMPORT_BATCH_SIZE", "10"))
    route_re = re.compile(r"^(?P<subject>[^@/]+)@(?P<group>[^/]+)/(?P<project>[^/]+)$")
    allowed_projects = {
        value.strip()
        for value in os.environ.get("AIS_EDGE_AUTO_IMPORT_ALLOWED_PROJECTS", "").split(",")
        if value.strip()
    }

    session = requests.Session()
    parsed = urllib.parse.urlsplit(orthanc_url)
    if parsed.username or parsed.password:
        session.auth = (
            urllib.parse.unquote(parsed.username or ""),
            urllib.parse.unquote(parsed.password or ""),
        )
        netloc = parsed.hostname or ""
        if parsed.port:
            netloc = f"{netloc}:{parsed.port}"
        orthanc_url = urllib.parse.urlunsplit(
            (parsed.scheme, netloc, parsed.path.rstrip("/"), "", "")
        )
    else:
        orthanc_url = orthanc_url.rstrip("/")

    def log(event, **fields):
        payload = {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "component": "sort-auto-label",
            "event": event,
        }
        payload.update(fields)
        print(json.dumps(payload), flush=True)

    def get_json(path):
        response = session.get(f"{orthanc_url}{path}", timeout=30)
        response.raise_for_status()
        return response.json()

    labelled = 0
    inspected = 0
    for study_id in get_json("/studies"):
        if labelled >= batch_size:
            break
        inspected += 1
        labels = set(get_json(f"/studies/{study_id}/labels"))
        if ready_label in labels or skip_label in labels:
            continue

        study = get_json(f"/studies/{study_id}")
        tags = {
            **study.get("MainDicomTags", {}),
            **study.get("PatientMainDicomTags", {}),
        }
        route_value = str(tags.get(route_field) or "").strip()
        route_match = route_re.match(route_value)

        if not route_match:
            if require_route_match:
                continue
            target_project = fallback_project
            target_kind = "fallback"
        else:
            target_project = route_match.group("project")
            target_kind = "routed"

        if route_match and allowed_projects:
            if target_project not in allowed_projects:
                log(
                    "auto_label_skipped_project",
                    study=study_id,
                    project=target_project,
                    message="project is not in AIS_EDGE_AUTO_IMPORT_ALLOWED_PROJECTS",
                )
                continue

        response = session.put(
            f"{orthanc_url}/studies/{study_id}/labels/{ready_label}",
            timeout=30,
        )
        response.raise_for_status()
        labelled += 1
        log(
            "auto_labelled_ready",
            study=study_id,
            field=route_field,
            value=route_value,
            label=ready_label,
            target_project=target_project,
            target_kind=target_kind,
        )

    log("auto_label_summary", inspected=inspected, labelled=labelled)
  route-staged-sessions.py: |
    import datetime
    import json
    import os
    import re
    import shutil
    import sys
    from pathlib import Path

    import yaml

    build_dir = Path(sys.argv[1])
    publish_dir = Path(sys.argv[2])
    route_enabled = os.environ.get("AIS_EDGE_PATIENTID_ROUTING", "").lower() in {
        "1",
        "true",
        "yes",
        "on",
    }
    route_field = os.environ.get("AIS_EDGE_PATIENTID_ROUTING_FIELD", "PatientID")
    route_re = re.compile(r"^(?P<subject>[^@/]+)@(?P<group>[^/]+)/(?P<project>[^/]+)$")
    xnat_id_re = re.compile(r"[^a-zA-Z0-9_]+")

    def xnat_id(value, fallback="UNKNOWN"):
        value = xnat_id_re.sub("_", str(value or "")).strip("_")
        return value or fallback

    def log(event, **fields):
        payload = {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "component": "sort-router",
            "event": event,
        }
        payload.update(fields)
        print(json.dumps(payload), flush=True)

    def merge_dir(src, dest):
        dest.mkdir(parents=True, exist_ok=True)
        for child in src.iterdir():
            target = dest / child.name
            if child.is_dir() and target.exists():
                merge_dir(child, target)
            elif target.exists():
                log(
                    "route_conflict",
                    source=str(child),
                    target=str(target),
                    message="target exists; leaving existing file in place",
                )
            else:
                shutil.move(str(child), str(target))
        shutil.rmtree(src)

    def invalid_dest(session_name):
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        dest = publish_dir / "__invalid__" / f"{session_name}.{stamp}"
        counter = 1
        while dest.exists():
            dest = publish_dir / "__invalid__" / f"{session_name}.{stamp}.{counter}"
            counter += 1
        return dest

    def validate_session(session_dir):
        metadata_path = session_dir / "METADATA.yaml"
        if not metadata_path.exists():
            return False, "missing METADATA.yaml"

        manifests = list(session_dir.rglob("MANIFEST.json"))
        if not manifests:
            return False, "missing resource manifests"

        for manifest_path in manifests:
            try:
                manifest = json.loads(manifest_path.read_text())
            except Exception as exc:
                return False, f"invalid manifest {manifest_path}: {exc}"
            for name in manifest.get("checksums", {}):
                if not (manifest_path.parent / name).exists():
                    return False, f"manifest references missing file {manifest_path.parent / name}"

        return True, ""

    def visit_from_name(session_name):
        parts = session_name.split(".", 2)
        if len(parts) == 3 and parts[2]:
            return parts[2]
        return "UNKNOWN"

    for session_dir in sorted(p for p in build_dir.iterdir() if p.is_dir()):
        if session_dir.name.startswith("__"):
            continue

        valid, reason = validate_session(session_dir)
        if not valid:
            dest = invalid_dest(session_dir.name)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(session_dir), str(dest))
            log(
                "session_quarantined",
                source=session_dir.name,
                target=str(dest),
                message=reason,
            )
            continue

        metadata_path = session_dir / "METADATA.yaml"
        metadata = {}
        if metadata_path.exists():
            with metadata_path.open() as f:
                metadata = yaml.safe_load(f) or {}

        target_name = session_dir.name
        routed = False
        raw_value = metadata.get(route_field)

        if route_enabled and raw_value:
            match = route_re.match(str(raw_value).strip())
            if match:
                project = xnat_id(match.group("project"))
                subject = xnat_id(match.group("subject"))
                group = xnat_id(match.group("group"))
                visit = visit_from_name(session_dir.name)
                target_name = f"{project}.{subject}.{visit}"
                routed = True
                log(
                    "session_routed",
                    source=session_dir.name,
                    target=target_name,
                    field=route_field,
                    group=group,
                    project=project,
                    subject=subject,
                )
            else:
                log(
                    "route_skipped",
                    source=session_dir.name,
                    field=route_field,
                    message="field does not match subject@group/project",
                )

        target_dir = publish_dir / target_name
        if target_dir.exists():
            merge_dir(session_dir, target_dir)
        else:
            shutil.move(str(session_dir), str(target_dir))

        if not routed:
            log("session_published", source=session_dir.name, target=target_name)
---
# Sort pod: REST-pulls instances from Orthanc, hardlinks the DICOM files
# from Orthanc's storage tree into staging. By default Orthanc is the
# repo-managed Service in this namespace, but deployments with an existing
# facility Orthanc can point ORTHANC_URL at that API and bind-mount the
# existing Orthanc storage into the DATA_HOST_PATH tree before bootstrap.
#
# Hardlink requires same filesystem, which is why the default managed
# Orthanc pod and this pod share the same /data hostPath. For an existing
# Orthanc, bind-mount or otherwise expose its storage under the same
# hostPath used for staging to avoid EXDEV hardlink failures.
#
# Label contract with Orthanc:
#   --orthanc-label xnat-ingest-ready   only consider instances with this label
#                                   (added by the Orthanc Lua label hook)
#   --orthanc-skip-label xnat-ingest-skip   skip instances already staged
#                                   (sort adds this label after hardlink)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xnat-ingest-sort
  namespace: xnat-ingest
  labels:
    app: xnat-ingest
    component: sort
spec:
  replicas: 1
  selector:
    matchLabels:
      app: xnat-ingest
      component: sort
  template:
    metadata:
      labels:
        app: xnat-ingest
        component: sort
    spec:
      {{#ONPREM_ONLY}}
      # Pod-level /etc/hosts so any in-pod tool can resolve the
      # management hostnames without external DNS. On cloud topology the
      # whole block is stripped — edges resolve via real public DNS.
      hostAliases:
        - ip: "{{MGMT_NODE_IP}}"
          hostnames:
            - "{{SEAWEEDFS_HOSTNAME}}"
            - "{{K0S_API_HOSTNAME}}"
            - "{{KONNECTIVITY_HOSTNAME}}"
            - "{{LOKI_HOSTNAME}}"
            - "{{GRAFANA_HOSTNAME}}"
      {{/ONPREM_ONLY}}
      containers:
        - name: sort
          # Default points at our fork on ghcr.io with the JSON-logging
          # patch. Override XNAT_INGEST_IMAGE in config/management.env to
          # switch (e.g. to upstream once merged).
          image: {{XNAT_INGEST_IMAGE}}
          command: ["/bin/sh", "/opt/ais-edge-sort-wrapper/sort-wrapper.sh"]
          args:
            - "--orthanc-url"
            - "{{ORTHANC_URL}}"
            - "--orthanc-storage-dir"
            - "{{ORTHANC_STORAGE_DIR}}"
{{ORTHANC_LABEL_ARGS}}
            - "--project-id"
            - "{{PROJECT_ID}}"
            - "--visit-field"
            - "AccessionNumber"
            - "generic/file-set"
            - "--visit-field"
            - "StudyID"
            - "generic/file-set"
            - "--wait-period"
            - "{{INGEST_WAIT_PERIOD}}"
          env:
            - name: AIS_LOG_FORMAT
              value: "json"
            - name: INGEST_LOOP_SECONDS
              value: "{{INGEST_LOOP_SECONDS}}"
            - name: AIS_EDGE_PATIENTID_ROUTING
              value: "{{EDGE_PATIENTID_PROJECT_ROUTING}}"
            - name: AIS_EDGE_PATIENTID_ROUTING_FIELD
              value: "{{EDGE_PATIENTID_PROJECT_ROUTING_FIELD}}"
            - name: AIS_EDGE_AUTO_IMPORT_UNLABELED
              value: "{{EDGE_AUTO_IMPORT_UNLABELED}}"
            - name: AIS_EDGE_AUTO_IMPORT_REQUIRE_ROUTING_MATCH
              value: "{{EDGE_AUTO_IMPORT_REQUIRE_ROUTING_MATCH}}"
            - name: AIS_EDGE_AUTO_IMPORT_BATCH_SIZE
              value: "{{EDGE_AUTO_IMPORT_BATCH_SIZE}}"
            - name: AIS_EDGE_AUTO_IMPORT_ALLOWED_PROJECTS
              value: "{{EDGE_AUTO_IMPORT_ALLOWED_PROJECTS}}"
          volumeMounts:
            - name: data
              mountPath: /data
            - name: sort-wrapper
              mountPath: /opt/ais-edge-sort-wrapper
              readOnly: true
      volumes:
        - name: data
          hostPath:
            path: {{EDGE_DATA_HOST_PATH}}
            type: DirectoryOrCreate
        - name: sort-wrapper
          configMap:
            name: xnat-ingest-sort-wrapper
---
# S3 uploader: watches /data/staging for completed sessions, mirrors them
# to SeaweedFS via the S3 API using `mc mirror`. mc handles multipart upload,
# parallel chunks, checksums, and retry — same protocol as MinIO, AWS S3.
#
# Phase 2:
#   - S3_ENDPOINT switched to https://{{SEAWEEDFS_HOSTNAME}} (port 443)
#   - The CA bundle Secret "ca-bundle" is mounted at /root/.mc/certs/CAs/
#     so mc trusts the seaweedfs-tls cert (issued by ais-edge-ca-issuer)
#   - hostAliases resolves the SNI hostname to MGMT_NODE_IP
apiVersion: apps/v1
kind: Deployment
metadata:
  name: s3-uploader
  namespace: xnat-ingest
  labels:
    app: xnat-ingest
    component: s3-uploader
spec:
  replicas: 1
  selector:
    matchLabels:
      app: xnat-ingest
      component: s3-uploader
  template:
    metadata:
      labels:
        app: xnat-ingest
        component: s3-uploader
    spec:
      {{#ONPREM_ONLY}}
      # Onprem-only: in onprem topology, edges have no DNS for the public
      # hostnames so we pin them to MGMT_NODE_IP via hostAliases. In cloud
      # topology this whole block is stripped — edges resolve via real
      # public DNS (e.g. nip.io or your own zone) to the LB VIP. Leaving
      # it in for a cloud install would pin the LB hostname to the mgmt
      # VM IP and silently break uploads.
      hostAliases:
        - ip: "{{MGMT_NODE_IP}}"
          hostnames:
            - "{{SEAWEEDFS_HOSTNAME}}"
            - "{{K0S_API_HOSTNAME}}"
            - "{{KONNECTIVITY_HOSTNAME}}"
            - "{{LOKI_HOSTNAME}}"
            - "{{GRAFANA_HOSTNAME}}"
      {{/ONPREM_ONLY}}
      containers:
        - name: uploader
          image: minio/mc:latest
          env:
            - name: S3_ENDPOINT
              value: "https://{{SEAWEEDFS_HOSTNAME}}"
            - name: S3_BUCKET
              value: "{{S3_BUCKET}}"
            - name: EDGE_NAME
              value: "{{CLUSTER_NAME}}"
            - name: MC_MIRROR_MAX_WORKERS
              value: "{{S3_UPLOAD_MAX_WORKERS}}"
            - name: MC_MIRROR_LIMIT_UPLOAD
              value: "{{S3_UPLOAD_LIMIT_UPLOAD}}"
            - name: S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-edge-credentials
                  key: access-key
            - name: S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-edge-credentials
                  key: secret-key
          command: ["/bin/sh", "-c"]
          args:
            - |
              # Each meaningful pipeline event is emitted as one line of JSON
              # so the central log collector (Vector) can parse it without
              # regexes. Schema: {ts, component, edge, event, session?, ...}
              jlog() {
                # $1=event, $2=session (optional), $3=msg (optional), $4=extra-json (optional)
                printf '{"ts":"%s","component":"s3-uploader","edge":"%s","event":"%s","session":"%s","message":"%s"%s}\n' \
                  "$(date -Iseconds)" "${EDGE_NAME}" "$1" "${2:-}" "${3:-}" "${4:-}"
              }

              jlog startup "" "s3-uploader starting endpoint=${S3_ENDPOINT} bucket=${S3_BUCKET}"

              # mc speaks vanilla S3 — works against MinIO, SeaweedFS, AWS S3, etc.
              #
              # CRITICAL: configure_alias must succeed AND the alias must
              # actually round-trip to the S3 endpoint. If either fails we
              # exit non-zero so Kubernetes restarts the pod — never enter
              # the upload loop with a broken alias.
              #
              # Why: mc treats unaliased prefixes as LOCAL paths (an
              # undocumented usability footgun). Without this guard, an
              # `mc mirror /staging/SESSION/ edge/${S3_BUCKET}/...` with a
              # missing `edge` alias silently copies into the local
              # directory `./edge/${S3_BUCKET}/...`, reports exit 0, the
              # script logs upload_completed, and `rm -rf $session_dir`
              # then DELETES the staged data — all without anything
              # reaching S3. Found the hard way on a cloud install where
              # /etc/hosts staleness blocked the LB at startup.
              # Retry alias setup a few times — DNS / pod startup races
              # are not the same thing as a misconfigured pipeline, and
              # crashlooping for 30s of DNS warm-up wastes runway. Persist
              # mc's actual error to stderr so a real failure shows up in
              # logs instead of being hidden behind `>/dev/null 2>&1`.
              configure_alias() {
                local err
                err=$(mc alias set edge "${S3_ENDPOINT}" \
                                        "${S3_ACCESS_KEY}" \
                                        "${S3_SECRET_KEY}" 2>&1) \
                  || { echo "mc alias set: $err" >&2; return 1; }
                err=$(mc ls "edge/${S3_BUCKET}/" 2>&1) \
                  || { echo "mc ls edge/${S3_BUCKET}/: $err" >&2; return 1; }
              }

              attempt=0
              until configure_alias; do
                attempt=$((attempt+1))
                if [ "$attempt" -ge 12 ]; then
                  jlog alias_failed "" "mc alias set / probe failed after 12 attempts (60s) — refusing to start upload loop"
                  sleep 15
                  exit 1
                fi
                jlog alias_retrying "" "attempt $attempt/12 — DNS/endpoint not ready, retrying in 5s"
                sleep 5
              done
              jlog alias_configured "" "mc alias set edge + bucket probe OK"

              : "${MC_MIRROR_MAX_WORKERS:=2}"
              : "${MC_MIRROR_LIMIT_UPLOAD:=80MiB}"

              while true; do
                for session_dir in /data/staging/*/; do
                  session_name=$(basename "$session_dir")

                  # Skip internal staging directories created by xnat-ingest sort
                  case "$session_name" in
                    __build__|__invalid__|__metadata__|"*") continue ;;
                  esac

                  # The minio/mc image is distroless — only `mc`, busybox shell,
                  # and a small set of coreutils. `awk` and `find` are NOT
                  # included, so the previous `awk '{print $1}'` and `find ...`
                  # both errored with "not found" and the structured event
                  # carried bytes:0/files:0 even on successful uploads.
                  # These shell-builtin equivalents work in the bare busybox sh:
                  #   * du -sb prints "<bytes><tab><path>" — strip the tail with
                  #     parameter expansion to keep just the number.
                  #   * file count is total `du -a` lines (files+dirs) minus
                  #     `du` lines (dirs only); both `du` and `wc -l` are
                  #     present in the image since the original `find | wc -l`
                  #     pipeline was failing on `find`, not `wc`.
                  bytes_raw=$(du -sb "$session_dir" 2>/dev/null)
                  bytes=${bytes_raw%%[[:space:]]*}
                  bytes=${bytes:-0}
                  # `files` is the total count of S3 objects uploaded for this
                  # session (DICOMs + the auto-generated MANIFEST.json + any
                  # other per-session metadata). `dicoms` is the subset that
                  # are DICOM image files (.dcm / .DCM). Both fields are
                  # exposed in the event so dashboard / alert authors can
                  # pick the right one — "DICOMs received" should query
                  # dicoms; "S3 objects written" should query files.
                  #
                  # The minio/mc image is distroless: only `mc`, bash, and
                  # coreutils (du, wc, cut, etc.). awk/find/grep/sed are NOT
                  # present, so the DICOM-extension filter is implemented as
                  # a POSIX shell `case` pattern fed by a while-read pipe
                  # rather than `grep`.
                  total_lines=$(du -a "$session_dir" 2>/dev/null | wc -l)
                  dir_lines=$(du "$session_dir" 2>/dev/null | wc -l)
                  files=$((total_lines - dir_lines))
                  [ "$files" -lt 0 ] && files=0
                  dicoms=$(du -a "$session_dir" 2>/dev/null \
                    | while IFS= read -r line; do
                        case "$line" in
                          *.dcm|*.DCM) echo 1 ;;
                        esac
                      done | wc -l)
                  dicoms=${dicoms:-0}
                  jlog upload_started "$session_name" "" ",\"bytes\":${bytes},\"files\":${files},\"dicoms\":${dicoms}"

                  start_ts=$(date +%s)
                  incoming_target="edge/${S3_BUCKET}/incoming/${EDGE_NAME}/${session_name}/"
                  staged_target="edge/${S3_BUCKET}/staged/${session_name}/"

                  # Defence-in-depth: re-verify the alias is still good
                  # immediately before the mirror. If the S3 endpoint went
                  # away mid-loop, this skips the upload (and the rm) so
                  # the staged data is preserved for the next retry.
                  if ! mc ls "edge/${S3_BUCKET}/" >/dev/null 2>&1; then
                    jlog upload_skipped "$session_name" "S3 alias probe failed — preserving staged data for next retry" ""
                    continue
                  fi

                  # mc mirror: rsync-for-S3. Multipart, parallel, resumable.
                  # --json makes mc itself emit one JSON line per object
                  # transferred, indexed by Vector alongside our own events.
                  #
                  # Upload to an incoming prefix first. The management-side
                  # xnat-ingest-upload pod watches only staged/, so it cannot
                  # import a half-mirrored session. Once the incoming mirror
                  # succeeds, publish to staged/ in a second remote-side pass.
                  if mc --json mirror --overwrite --remove \
                      --max-workers "${MC_MIRROR_MAX_WORKERS}" \
                      --limit-upload "${MC_MIRROR_LIMIT_UPLOAD}" \
                      "$session_dir" "$incoming_target"; then
                    if mc --json mirror --overwrite --remove \
                        --max-workers "${MC_MIRROR_MAX_WORKERS}" \
                        "$incoming_target" "$staged_target"; then
                      mc rm --recursive --force "$incoming_target" >/dev/null 2>&1 || true
                      duration=$(( $(date +%s) - start_ts ))
                      jlog upload_completed "$session_name" "" \
                        ",\"bytes\":${bytes:-0},\"files\":${files:-0},\"dicoms\":${dicoms:-0},\"duration_s\":${duration}"
                      rm -rf "$session_dir"
                    else
                      duration=$(( $(date +%s) - start_ts ))
                      jlog upload_failed "$session_name" "publish from incoming to staged failed; preserving staged data for next retry" \
                        ",\"bytes\":${bytes:-0},\"files\":${files:-0},\"dicoms\":${dicoms:-0},\"duration_s\":${duration}"
                    fi
                  else
                    duration=$(( $(date +%s) - start_ts ))
                    jlog upload_failed "$session_name" "mc mirror non-zero exit; will retry next cycle" \
                      ",\"bytes\":${bytes:-0},\"files\":${files:-0},\"dicoms\":${dicoms:-0},\"duration_s\":${duration}"
                  fi
                done

                sleep 30
              done
          volumeMounts:
            - name: data
              mountPath: /data
            # mc reads PEM files in /root/.mc/certs/CAs/ as additional trust roots
            - name: ca-bundle
              mountPath: /root/.mc/certs/CAs
              readOnly: true
      volumes:
        - name: data
          hostPath:
            path: {{EDGE_DATA_HOST_PATH}}
            type: DirectoryOrCreate
        - name: ca-bundle
          secret:
            secretName: ca-bundle
            optional: true
