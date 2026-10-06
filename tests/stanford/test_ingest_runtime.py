#!/usr/bin/env python3
"""Run under the pinned xnat-ingest image, or a venv containing release 0.15.6."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from fileformats.core import FileSet
from xnat_ingest.api.assign_api import assign
from xnat_ingest.model.session import ImagingSession

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("stanford", ROOT / "charts/edge/files/stanford-ingest.py")
stanford = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stanford)

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    source, output, archive = (root / p for p in ("raw", "assigned", "archive"))
    subject = source / "polimeni/openrecon/test"
    subject.mkdir(parents=True)
    (subject / "raw.bin").write_bytes(b"raw")
    subprocess.run([sys.executable, str(ROOT / "charts/edge/files/stanford-stage-raw.py"),
                    str(source), str(output), str(archive)], check=True,
                   env={**os.environ, "AIS_EDGE_SAMBA_UPLOAD_ENABLED": "1",
                        "AIS_EDGE_SAMBA_UPLOAD_WAIT_PERIOD": "0", "AIS_EDGE_SAMBA_UPLOAD_ALLOWED_PROJECTS": ""})
    loaded = ImagingSession.load(output / "openrecon.test.samba_upload")
    assert loaded.project_id == "openrecon"
    assert loaded.subject_id == "test"
    assert loaded.metadata["SourceGroup"] == "polimeni"
    assert loaded.scans["1"].resources["FILES"].checksums == {"raw.bin": hashlib.md5(b"raw").hexdigest()}
    print("PASS: raw session loads with the pinned uploader's metadata and checksums")

    # A grouped session uses the new pre-assignment prefix and metadata filename.
    grouped = root / "grouped"
    session = grouped / "_.1.2.3"
    resource = session / "1.Raw/FILES"
    resource.mkdir(parents=True)
    (resource / "test.bin").write_bytes(b"test")
    (resource / "__MANIFEST__.json").write_text(json.dumps({"datatype": "generic/file-set",
        "checksums": {"test.bin": hashlib.md5(b"test").hexdigest()}}))
    metadata = {"__uid__": "1.2.3", "Modality": "MR", "PatientID": "subject@polimeni/openrecon", "AccessionNumber": "visit"}
    config = {"fallbackProject": "misc", "routing": {"enabled": True, "field": "PatientID", "visitFields": ["AccessionNumber"]}}
    stanford.route_metadata(metadata, config)
    (session / "__METADATA__.json").write_text(json.dumps(metadata))
    errors = assign(grouped, root / "build", "StanfordProject", "StanfordSubject", "StanfordVisit", unlink_source="all", raise_errors=True)
    assert not errors, errors
    result = ImagingSession.load(root / "build/openrecon.subject.visit")
    assert result.metadata["SourceGroup"] == "polimeni"
    assert result.project_id == "openrecon"
    assert not session.exists()
    print("PASS: pinned assign honors routed IDs and carries SourceGroup into upload metadata")
