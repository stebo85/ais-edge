"""Stanford's pre-deidentified Orthanc and raw-file paths, using xnat-ingest 0.15."""
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROUTE = re.compile(r"^(?P<subject>[^@/]+)@(?P<group>[^/]+)/(?P<project>[^/]+)$")


def xnat_id(value):
    return re.sub(r"[^A-Za-z0-9_]+", "_", str(value or "")).strip("_") or "UNKNOWN"


def log(event, **fields):
    print(json.dumps({"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      "component": "stanford-ingest", "event": event, **fields}), flush=True)


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, indent=2)
    if path.exists() and path.read_text() == text:
        return
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(text)
    temp.replace(path)


def route_metadata(metadata, config):
    routing = config["routing"]
    match = ROUTE.fullmatch(str(metadata.get(routing["field"], "")).strip())
    routed = routing["enabled"] and match is not None
    if routed:
        metadata["StanfordProject"] = xnat_id(match["project"])
        metadata["StanfordSubject"] = xnat_id(match["subject"])
        metadata["SourceGroup"] = match["group"]
    else:
        metadata["StanfordProject"] = config["fallbackProject"]
        metadata["StanfordSubject"] = xnat_id(metadata.get("PatientID"))
    metadata["StanfordVisit"] = xnat_id(next(
        (metadata.get(field) for field in routing["visitFields"] if metadata.get(field)),
        metadata.get("__uid__", "UNKNOWN")))
    return routed


def auto_label(config):
    routing = config["routing"]
    if not routing["autoImportUnlabeled"]:
        return
    import requests
    session = requests.Session()
    session.auth = (os.environ.get("ORTHANC_USER", ""), os.environ.get("ORTHANC_PASSWORD", ""))
    url = os.environ["ORTHANC_URL"].rstrip("/")

    def get(path):
        response = session.get(url + path, timeout=30)
        response.raise_for_status()
        return response.json()

    labelled = 0
    for study_id in get("/studies"):
        if labelled >= routing["batchSize"]:
            break
        labels = get(f"/studies/{study_id}/labels")
        if os.environ["ORTHANC_READY_LABEL"] in labels or os.environ["ORTHANC_PROCESSED_LABEL"] in labels:
            continue
        study = get(f"/studies/{study_id}")
        if not study.get("IsStable", False):
            continue
        metadata = {**study.get("MainDicomTags", {}), **study.get("PatientMainDicomTags", {})}
        match = ROUTE.fullmatch(str(metadata.get(routing["field"], "")).strip())
        if routing["requireMatch"] and not match:
            continue
        if match and routing["allowedProjects"] and match["project"] not in routing["allowedProjects"]:
            continue
        response = session.put(url + f"/studies/{study_id}/labels/" + os.environ["ORTHANC_READY_LABEL"], timeout=30)
        response.raise_for_status()
        labelled += 1
        log("auto_labelled_ready", study=study_id)


def publish(build, assigned):
    """Publish complete sessions atomically; leave collisions intact for the next pass."""
    assigned.mkdir(parents=True, exist_ok=True)
    for source in sorted(build.iterdir()):
        if not source.is_dir() or source.name.startswith("__"):
            continue
        destination = assigned / source.name
        if destination.exists():
            log("session_publish_deferred", session=source.name)
            continue
        source.rename(destination)
        log("session_published", session=destination.name)


def ingest_once(config):
    grouped, assigned = Path("/data/grouped"), Path("/data/assigned")
    build = Path("/data/__stanford__/assigned")
    for path in (grouped, assigned, build):
        path.mkdir(parents=True, exist_ok=True)
    publish(build, assigned)
    try:
        ingest_dicom(config, grouped, assigned, build)
    except Exception as exc:
        log("orthanc_ingest_failed", message=str(exc))
    if config["rawUploads"]["enabled"]:
        raw = config["rawUploads"]
        env = {**os.environ, "AIS_EDGE_SAMBA_UPLOAD_ENABLED": "1",
               "AIS_EDGE_STATE_DIR": "/data/LOGS/stanford-raw",
               "AIS_EDGE_SAMBA_UPLOAD_WAIT_PERIOD": str(raw["waitPeriod"]),
               "AIS_EDGE_SAMBA_UPLOAD_VISIT": raw["visit"],
               "AIS_EDGE_SAMBA_UPLOAD_SCAN": raw["scan"],
               "AIS_EDGE_SAMBA_UPLOAD_RESOURCE": raw["resource"],
               "AIS_EDGE_SAMBA_UPLOAD_MODALITY": raw["modality"],
               "AIS_EDGE_SAMBA_UPLOAD_ALLOWED_PROJECTS": ",".join(raw["allowedProjects"])}
        subprocess.run([sys.executable, str(Path(__file__).with_name("stanford-stage-raw.py")),
                        "/stanford-upload", str(assigned), "/stanford-upload-done"], env=env, check=True)


def ingest_dicom(config, grouped, assigned, build):
    if os.environ["ORTHANC_GROUP_ENABLED"] == "true":
        auto_label(config)
        subprocess.run(["xnat-ingest", "group-orthanc", os.environ["ORTHANC_URL"],
                        os.environ["ORTHANC_STORAGE_DIR"], str(grouped),
                        os.environ.get("ORTHANC_USER", ""), os.environ.get("ORTHANC_PASSWORD", ""),
                        "--to-process-label", os.environ["ORTHANC_READY_LABEL"],
                        "--processed-label", os.environ["ORTHANC_PROCESSED_LABEL"],
                        "--wait-period", os.environ["ORTHANC_WAIT_PERIOD"]], check=True)
        cache = Path("/data/LOGS/stanford-routed-projects.json")
        routed_projects = set(json.loads(cache.read_text())) if cache.exists() else set()
        for source in sorted(grouped.iterdir()):
            metadata_path = source / "__METADATA__.json"
            if not source.is_dir() or not metadata_path.exists():
                continue
            metadata = json.loads(metadata_path.read_text())
            if route_metadata(metadata, config):
                routed_projects.add(metadata["StanfordProject"])
            write_json(metadata_path, metadata)
            # Excluded scanner reports remain in the external Orthanc store.
            for scan in source.iterdir():
                description = scan.name.partition(".")[2]
                scan_meta = scan / "__METADATA__.json"
                if scan_meta.is_file():
                    description = json.loads(scan_meta.read_text()).get("SeriesDescription", description)
                if description in config["excludeDicomScanTypes"]:
                    dicom = scan / "DICOM"
                    if dicom.is_dir():
                        shutil.rmtree(dicom)
        write_json(cache, sorted(routed_projects))
        args = ["xnat-ingest", "assign", str(grouped), str(build), "--project", "StanfordProject",
                "--subject", "StanfordSubject", "--session", "StanfordVisit"]
        if os.environ["GROUPED_RECLAIM"] == "onAssigned":
            args += ["--unlink-source", "all"]
        subprocess.run(args, check=True)
        publish(build, assigned)


def main():
    config = json.loads(Path("/etc/stanford/config.json").read_text())
    while True:
        start = time.monotonic()
        try:
            ingest_once(config)
        except Exception as exc:
            log("stanford_ingest_failed", message=str(exc))
        time.sleep(max(1, int(os.environ.get("INGEST_INTERVAL", "60")) - (time.monotonic() - start)))


if __name__ == "__main__":
    main()
