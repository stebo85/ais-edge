import datetime
import hashlib
import json
import os
import re
import shutil
import sys
import time
import traceback
from pathlib import Path

enabled = os.environ.get("AIS_EDGE_SAMBA_UPLOAD_ENABLED", "").lower() in {
    "1",
    "true",
    "yes",
    "on",
}
if not enabled:
    sys.exit(0)

source_root = Path(sys.argv[1])
publish_dir = Path(sys.argv[2])
archive_root = Path(sys.argv[3])
wait_period = int(
    os.environ.get(
        "AIS_EDGE_SAMBA_UPLOAD_WAIT_PERIOD",
        os.environ.get("INGEST_WAIT_PERIOD", "60"),
    )
)
visit_id = os.environ.get("AIS_EDGE_SAMBA_UPLOAD_VISIT", "samba_upload")
scan_dir_name = os.environ.get("AIS_EDGE_SAMBA_UPLOAD_SCAN", "1.SambaUpload")
resource_name = os.environ.get("AIS_EDGE_SAMBA_UPLOAD_RESOURCE", "FILES")
modality = os.environ.get("AIS_EDGE_SAMBA_UPLOAD_MODALITY", "MR")
allowed_projects = {
    value.strip()
    for value in os.environ.get(
        "AIS_EDGE_SAMBA_UPLOAD_ALLOWED_PROJECTS",
        os.environ.get("AIS_EDGE_AUTO_IMPORT_ALLOWED_PROJECTS", ""),
    ).split(",")
    if value.strip()
}

cache_path = Path(os.environ.get("AIS_EDGE_ROUTED_PROJECTS", "/data/LOGS/stanford-routed-projects.json"))
if allowed_projects and cache_path.exists():
    allowed_projects.update(json.loads(cache_path.read_text()))

state_dir = Path(os.environ.get("AIS_EDGE_STATE_DIR", str(publish_dir / "__metadata__")))
state_path = state_dir / "samba-upload-state.json"
build_root = publish_dir / "__samba_build__"
xnat_id_re = re.compile(r"[^a-zA-Z0-9_]+")

def xnat_id(value, fallback="UNKNOWN"):
    value = xnat_id_re.sub("_", str(value or "")).strip("_")
    return value or fallback

visit_id = xnat_id(visit_id, "samba_upload")

def log(event, **fields):
    payload = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "component": "samba-upload-stager",
        "event": event,
    }
    payload.update(fields)
    print(json.dumps(payload), flush=True)

def load_state():
    if not state_path.exists():
        return {}
    try:
        return json.loads(state_path.read_text())
    except Exception as exc:
        log("samba_state_reset", message=f"failed to read state: {exc}")
        return {}

def save_state(state):
    state_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = state_path.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp_path.replace(state_path)

def file_snapshot(subject_dir):
    total_bytes = 0
    files = 0
    latest_mtime_ns = subject_dir.stat().st_mtime_ns
    for root, dirnames, filenames in os.walk(subject_dir):
        dirnames[:] = [name for name in dirnames if not name.startswith(".")]
        for filename in filenames:
            if filename.startswith("."):
                continue
            path = Path(root) / filename
            if not path.is_file():
                continue
            stat = path.stat()
            files += 1
            total_bytes += stat.st_size
            latest_mtime_ns = max(latest_mtime_ns, stat.st_mtime_ns)
    if files == 0:
        return None
    return {
        "files": files,
        "bytes": total_bytes,
        "latest_mtime_ns": latest_mtime_ns,
    }

def same_snapshot(prev, snap):
    return (
        prev
        and prev.get("files") == snap["files"]
        and prev.get("bytes") == snap["bytes"]
        and prev.get("latest_mtime_ns") == snap["latest_mtime_ns"]
    )

def iter_subject_dirs():
    if not source_root.exists():
        log("samba_source_missing", source=str(source_root))
        return
    for group_dir in sorted(p for p in source_root.iterdir() if p.is_dir()):
        if group_dir.name.startswith("."):
            continue
        for project_dir in sorted(p for p in group_dir.iterdir() if p.is_dir()):
            if project_dir.name.startswith("."):
                continue
            # A killed pickup leaves the claimed source hidden on the share.
            # Restore it for retry rather than silently stranding its only copy.
            for claimed in sorted(project_dir.glob(".*.ais-edge-pickup")):
                original = claimed.with_name(claimed.name[1:-len(".ais-edge-pickup")])
                if not original.exists():
                    claimed.rename(original)
                    log("samba_pickup_recovered", source=str(original))
                else:
                    log("samba_pickup_needs_recovery", source=str(claimed))
            for subject_dir in sorted(p for p in project_dir.iterdir() if p.is_dir()):
                if subject_dir.name.startswith("."):
                    continue
                yield group_dir, project_dir, subject_dir

def md5sum(path):
    digest = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def write_manifest(resource_dir):
    checksums = {}
    for path in sorted(p for p in resource_dir.rglob("*") if p.is_file()):
        if path.name == "__MANIFEST__.json":
            continue
        checksums[path.relative_to(resource_dir).as_posix()] = md5sum(path)
    manifest = {"datatype": "generic/file-set", "checksums": checksums}
    (resource_dir / "__MANIFEST__.json").write_text(json.dumps(manifest, indent=2))

def write_metadata(session_tmp, group, project, subject, archive_dest):
    metadata = {
        "Modality": modality,
        "Source": "samba-upload",
        "SourceGroup": group,
        "SourceProject": project,
        "SourceSubject": subject,
        "SourceArchive": str(archive_dest),
    }
    (session_tmp / "__METADATA__.json").write_text(json.dumps(metadata, indent=2))

def unique_build_path(prefix):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = build_root / f"{prefix}.{stamp}"
    counter = 1
    while path.exists():
        path = build_root / f"{prefix}.{stamp}.{counter}"
        counter += 1
    return path

def unique_archive_path(group, project, subject):
    base_dir = archive_root / group / project
    path = base_dir / subject
    if not path.exists():
        return path
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = base_dir / f"{subject}.{stamp}"
    counter = 1
    while path.exists():
        path = base_dir / f"{subject}.{stamp}.{counter}"
        counter += 1
    return path

def copy_child(src, dest):
    if src.is_dir():
        shutil.copytree(str(src), str(dest), copy_function=shutil.copy2)
    else:
        shutil.copy2(str(src), str(dest))

def copy_subject_to_resource(source_tmp, resource_dir):
    for child in source_tmp.iterdir():
        copy_child(child, resource_dir / child.name)

def restore_source(source_tmp, subject_dir):
    if source_tmp.exists() and not subject_dir.exists():
        subject_dir.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source_tmp), str(subject_dir))

def stage_subject(group_dir, project_dir, subject_dir, snap):
    group = group_dir.name
    raw_project = project_dir.name
    raw_subject = subject_dir.name
    project = xnat_id(raw_project)
    subject = xnat_id(raw_subject)

    if allowed_projects and raw_project not in allowed_projects and project not in allowed_projects:
        log(
            "samba_project_skipped",
            group=group,
            project=raw_project,
            subject=raw_subject,
            message="project is not in AIS_EDGE_SAMBA_UPLOAD_ALLOWED_PROJECTS",
        )
        return False, "skipped"

    session_name = f"{project}.{subject}.{visit_id}"
    target_dir = publish_dir / session_name
    if target_dir.exists():
        log(
            "samba_stage_deferred",
            group=group,
            project=project,
            subject=subject,
            session=session_name,
            message="target session is still staged; waiting for s3-uploader",
        )
        return False, "pending"

    build_root.mkdir(parents=True, exist_ok=True)
    archive_dest = unique_archive_path(group, raw_project, raw_subject)
    source_tmp = unique_build_path(f"source.{project}.{subject}")
    session_tmp = unique_build_path(f"session.{session_name}")

    # Claim the source on its own filesystem; copying between volumes is never a move.
    source_tmp = subject_dir.with_name("." + subject_dir.name + ".ais-edge-pickup")
    if source_tmp.exists():
        raise RuntimeError(f"unfinished pickup needs recovery: {source_tmp}")
    subject_dir.rename(source_tmp)
    try:
        archive_dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(str(source_tmp), str(archive_dest), copy_function=shutil.copy2)

        resource_dir = session_tmp / scan_dir_name / resource_name
        resource_dir.mkdir(parents=True, exist_ok=True)
        copy_subject_to_resource(source_tmp, resource_dir)
        write_manifest(resource_dir)
        write_metadata(session_tmp, group, raw_project, raw_subject, archive_dest)
        session_tmp.replace(target_dir)
    except Exception:
        shutil.rmtree(session_tmp, ignore_errors=True)
        if archive_dest.exists():
            shutil.rmtree(archive_dest, ignore_errors=True)
        restore_source(source_tmp, subject_dir)
        raise
    else:
        shutil.rmtree(source_tmp)
        # Leave the (now empty) group/project directories in place so
        # uploaders keep a stable folder structure to drop data into.

    log(
        "samba_session_staged",
        group=group,
        project=project,
        subject=subject,
        session=session_name,
        files=snap["files"],
        bytes=snap["bytes"],
        source=str(source_root / group / raw_project / raw_subject),
        archive=str(archive_dest),
        target=str(target_dir),
    )
    return True, "staged"

def main():
    publish_dir.mkdir(parents=True, exist_ok=True)
    state = load_state()
    next_state = {}
    now = time.time()
    scanned = 0
    staged = 0
    pending = 0
    skipped = 0

    for group_dir, project_dir, subject_dir in iter_subject_dirs() or []:
        snap = file_snapshot(subject_dir)
        if snap is None:
            continue
        scanned += 1
        key = "/".join(
            [
                group_dir.name,
                project_dir.name,
                subject_dir.name,
            ]
        )
        previous = state.get(key)
        first_seen = previous.get("first_seen", now) if same_snapshot(previous, snap) else now
        age = now - first_seen
        if age < wait_period:
            pending += 1
            next_state[key] = {**snap, "first_seen": first_seen}
            continue

        try:
            was_staged, status = stage_subject(group_dir, project_dir, subject_dir, snap)
        except Exception as exc:
            skipped += 1
            next_state[key] = {**snap, "first_seen": first_seen}
            log(
                "samba_stage_failed",
                source=str(subject_dir),
                message=str(exc),
                traceback=traceback.format_exc(),
            )
            continue

        if was_staged:
            staged += 1
        elif status == "pending":
            pending += 1
            next_state[key] = {**snap, "first_seen": first_seen}
        else:
            skipped += 1

    save_state(next_state)
    if scanned or staged or pending or skipped:
        log(
            "samba_stage_summary",
            scanned=scanned,
            staged=staged,
            pending=pending,
            skipped=skipped,
        )

main()
