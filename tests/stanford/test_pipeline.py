#!/usr/bin/env python3
import copy
import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import shutil
from unittest.mock import patch
from types import SimpleNamespace
import yaml
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ingest = load("stanford_ingest", "charts/edge/files/stanford-ingest.py")
projects = load("stanford_projects", "charts/mgmt/files/stanford-projects.py")
CONFIG = {"fallbackProject": "misc", "routing": {"enabled": True, "field": "PatientID",
          "visitFields": ["AccessionNumber", "StudyID", "StudyInstanceUID"]}}


class RoutingTests(unittest.TestCase):
    def test_routed_subject_project_and_owner(self):
        metadata = {"PatientID": "subject-1@polimeni/openrecon", "AccessionNumber": "visit-2"}
        self.assertTrue(ingest.route_metadata(metadata, CONFIG))
        self.assertEqual((metadata["StanfordProject"], metadata["StanfordSubject"], metadata["StanfordVisit"], metadata["SourceGroup"]),
                         ("openrecon", "subject_1", "visit_2", "polimeni"))

    def test_fallback_and_visit_priority(self):
        metadata = {"PatientID": "test", "StudyID": "study", "StudyInstanceUID": "1.2.3"}
        self.assertFalse(ingest.route_metadata(metadata, CONFIG))
        self.assertEqual((metadata["StanfordProject"], metadata["StanfordVisit"]), ("misc", "study"))
        self.assertNotIn("SourceGroup", metadata)

    def test_route_disabled_preserves_fallback(self):
        config = copy.deepcopy(CONFIG)
        config["routing"]["enabled"] = False
        metadata = {"PatientID": "s@g/p", "StudyID": "visit"}
        self.assertFalse(ingest.route_metadata(metadata, config))
        self.assertEqual(metadata["StanfordProject"], "misc")

    def test_publish_defers_collision_without_deleting_either_copy(self):
        with tempfile.TemporaryDirectory() as temp:
            build, assigned = Path(temp) / "build", Path(temp) / "assigned"
            source = build / "p.s.v"
            source.mkdir(parents=True)
            (source / "new.txt").write_text("new")
            target = assigned / source.name
            target.mkdir(parents=True)
            (target / "old.txt").write_text("old")
            with redirect_stdout(io.StringIO()):
                ingest.publish(build, assigned)
            self.assertEqual((source / "new.txt").read_text(), "new")
            self.assertEqual((target / "old.txt").read_text(), "old")


class RawUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.source, self.assigned, self.archive = (self.base / p for p in ("source", "assigned", "archive"))
        self.subject = self.source / "polimeni" / "openrecon" / "test"
        self.subject.mkdir(parents=True)
        self.env = {**os.environ, "AIS_EDGE_SAMBA_UPLOAD_ENABLED": "1", "AIS_EDGE_SAMBA_UPLOAD_WAIT_PERIOD": "0",
                    "AIS_EDGE_SAMBA_UPLOAD_ALLOWED_PROJECTS": "", "AIS_EDGE_STATE_DIR": str(self.base / "state"),
                    "AIS_EDGE_ROUTED_PROJECTS": str(self.base / "routed.json")}

    def tearDown(self):
        self.temp.cleanup()

    def run_stage(self):
        return subprocess.run([sys.executable, str(ROOT / "charts/edge/files/stanford-stage-raw.py"),
                               str(self.source), str(self.assigned), str(self.archive)],
                              env=self.env, capture_output=True, text=True, check=True)

    def test_empty_folder_does_not_stage(self):
        self.run_stage()
        self.assertTrue(self.subject.exists())
        self.assertFalse((self.assigned / "openrecon.test.samba_upload").exists())

    def test_raw_session_manifest_owner_archive_and_folder_retention(self):
        (self.subject / "nested").mkdir()
        (self.subject / "nested" / "data.bin").write_bytes(b"raw-data")
        self.env["AIS_EDGE_AUTO_IMPORT_ALLOWED_PROJECTS"] = "restricted_dicom_project"
        self.run_stage()
        target = self.assigned / "openrecon.test.samba_upload"
        self.assertEqual((target / "1.SambaUpload/FILES/nested/data.bin").read_bytes(), b"raw-data")
        metadata = json.loads((target / "__METADATA__.json").read_text())
        self.assertEqual(metadata["SourceGroup"], "polimeni")
        manifest = json.loads((target / "1.SambaUpload/FILES/__MANIFEST__.json").read_text())
        self.assertIn("nested/data.bin", manifest["checksums"])
        self.assertEqual((self.archive / "polimeni/openrecon/test/nested/data.bin").read_bytes(), b"raw-data")
        self.assertFalse(self.subject.exists())
        self.assertTrue(self.subject.parent.is_dir())

    def test_restricted_raw_projects_extend_from_routed_cache(self):
        (self.subject / "raw.bin").write_bytes(b"raw")
        self.env["AIS_EDGE_SAMBA_UPLOAD_ALLOWED_PROJECTS"] = "other_project"
        self.run_stage()
        self.assertTrue(self.subject.exists())
        (self.base / "routed.json").write_text('["openrecon"]')
        self.run_stage()
        self.assertFalse(self.subject.exists())

    def test_archive_failure_restores_source(self):
        (self.subject / "raw.bin").write_bytes(b"raw")
        self.archive.write_text("not a directory")
        result = self.run_stage()
        self.assertIn("samba_stage_failed", result.stdout)
        self.assertEqual((self.subject / "raw.bin").read_bytes(), b"raw")
        self.assertFalse((self.assigned / "openrecon.test.samba_upload").exists())

    def test_existing_assigned_session_keeps_new_source_for_later(self):
        (self.subject / "raw.bin").write_bytes(b"new")
        target = self.assigned / "openrecon.test.samba_upload"
        target.mkdir(parents=True)
        (target / "old.bin").write_bytes(b"old")
        self.run_stage()
        self.assertEqual((self.subject / "raw.bin").read_bytes(), b"new")
        self.assertEqual((target / "old.bin").read_bytes(), b"old")

    def test_interrupted_pickup_is_recovered(self):
        (self.subject / "raw.bin").write_bytes(b"raw")
        self.subject.rename(self.subject.with_name(".test.ais-edge-pickup"))
        self.run_stage()
        self.assertEqual((self.archive / "polimeni/openrecon/test/raw.bin").read_bytes(), b"raw")

    def test_new_write_resets_quiet_period(self):
        (self.subject / "raw.bin").write_bytes(b"first")
        self.env["AIS_EDGE_SAMBA_UPLOAD_WAIT_PERIOD"] = "60"
        self.run_stage()
        statefile = self.base / "state/samba-upload-state.json"
        state = json.loads(statefile.read_text())
        state["polimeni/openrecon/test"]["first_seen"] -= 120
        statefile.write_text(json.dumps(state))
        (self.subject / "raw.bin").write_bytes(b"changed")
        self.run_stage()
        self.assertTrue(self.subject.exists())


class Response:
    def __init__(self, status=200, payload=None):
        self.status_code, self.payload = status, payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError("HTTP " + str(self.status_code))

    def json(self):
        return self.payload or {}


class FakeXNAT:
    def __init__(self, owners=(), missing_project=False, missing_users=()):
        self.owners, self.missing_project, self.missing_users = set(owners), missing_project, set(missing_users)
        self.puts = []
        self.posts = []

    def get(self, url, **kwargs):
        if "/data/users?" in url:
            users = {"polimeni", "brosnan", "sciget"} - self.missing_users
            return Response(payload=[{"login": name} for name in users])
        if "/users?" in url:
            return Response(payload={"ResultSet": {"Result": [{"login": owner, "displayname": "Owners"} for owner in self.owners]}})
        return Response(404 if self.missing_project else 200)

    def post(self, url, **kwargs):
        self.posts.append((url, kwargs["data"]))
        self.missing_project = False
        return Response(201)

    def put(self, url, **kwargs):
        self.puts.append(url)
        if "/users/Owners/" in url:
            owner = url.rsplit("/", 1)[1]
            if owner in self.missing_users:
                return Response(404)
            self.owners.add(owner)
        else:
            self.missing_project = False
        return Response()


class ProvisioningTests(unittest.TestCase):
    def test_create_and_verify_group_and_default_owners(self):
        xnat = FakeXNAT(missing_project=True)
        with redirect_stdout(io.StringIO()):
            projects.ensure_project(xnat, "http://xnat", "openrecon", ["polimeni", "brosnan", "sciget"])
        self.assertEqual(xnat.owners, {"polimeni", "brosnan", "sciget"})
        self.assertEqual(xnat.posts[0][0], "http://xnat/data/projects")
        import xml.etree.ElementTree as ET
        document = ET.fromstring(xnat.posts[0][1])
        self.assertEqual(document.tag, "{http://nrg.wustl.edu/xnat}Project")
        self.assertEqual(document.attrib, {"ID": "openrecon", "secondary_ID": "openrecon"})
        self.assertFalse(any("/data/users/" in url for url in xnat.puts))

    def test_existing_owner_is_idempotent(self):
        xnat = FakeXNAT(owners=["polimeni"])
        projects.ensure_project(xnat, "http://xnat", "openrecon", ["polimeni"])
        self.assertEqual(xnat.puts, [])

    def test_unknown_user_deferred_without_creating_account(self):
        xnat = FakeXNAT(missing_users=["unknown"])
        with redirect_stdout(io.StringIO()) as output:
            projects.ensure_project(xnat, "http://xnat", "openrecon", ["unknown", "brosnan"])
        self.assertIn("project_owner_deferred", output.getvalue())
        self.assertEqual(xnat.owners, {"brosnan"})
        self.assertFalse(any(url.endswith("/unknown") for url in xnat.puts))
        self.assertFalse(any("/data/users/" in url for url in xnat.puts))


class ArchiveTests(unittest.TestCase):
    def run_archive(self, scenario):
        script = (ROOT / "charts/mgmt/files/reclaim-staged.sh").read_text()
        functions = script[script.index("archive_session() {"):script.index("# Main pass", script.index("archive_session() {"))]
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            env = {**os.environ, "SCENARIO": scenario, "CALL_LOG": str(temp / "calls"),
                   "ARCHIVE_PREFIX": "uploaded", "S3_PREFIX": "staged", "STATE_PREFIX": ".reclaim-state",
                   "S3_BUCKET": "ingest-bucket", "FILER_ENDPOINT": "http://filer", "HTTP_TIMEOUT": "5"}
            stub = r'''
aws() {
    printf '%s\n' "$*" >> "$CALL_LOG"
    if [ "$1 $2" = 's3 cp' ]; then
        [ "$SCENARIO" != fail-copy ]; return
    fi
    local prefix size=3
    while [ $# -gt 0 ]; do
        if [ "$1" = --prefix ]; then prefix="$2"; break; fi
        shift
    done
    if [[ "$prefix" == uploaded/* ]] && [ "$SCENARIO" = mismatch ]; then size=2; fi
    printf '{"Contents":[{"Key":"%sdata.bin","Size":%s,"ETag":"abc","LastModified":"same"}]}\n' "$prefix" "$size"
}
timeout() { shift; "$@"; }
curl() { printf 'DELETE\n' >> "$CALL_LOG"; printf '\n204'; }
jlog() { :; }
'''
            result = subprocess.run(["bash", "-c", stub + functions + '\nfiler_rm p.s.v'], env=env, capture_output=True, text=True)
            return result, (temp / "calls").read_text()

    def test_success_copies_before_delete(self):
        result, calls = self.run_archive("success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(calls.index("s3 cp"), calls.index("DELETE"))

    def test_failed_copy_never_deletes_staging(self):
        result, calls = self.run_archive("fail-copy")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("DELETE", calls)

    def test_incomplete_archive_never_deletes_staging(self):
        result, calls = self.run_archive("mismatch")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("DELETE", calls)




class AutoLabelTests(unittest.TestCase):
    def test_only_stable_allowed_studies_are_labelled(self):
        put_urls = []
        class Orthanc:
            def get(self, url, **kwargs):
                path = url.removeprefix("http://orthanc")
                if path == "/studies":
                    return Response(payload=["stable", "unstable", "processed", "restricted"])
                if path.endswith("/labels"):
                    return Response(payload=["done"] if "/processed/" in path else [])
                return Response(payload={"IsStable": "/unstable" not in path,
                    "PatientMainDicomTags": {"PatientID": "s@g/" + ("blocked" if "/restricted" in path else "allowed")}})
            def put(self, url, **kwargs):
                put_urls.append(url)
                return Response()
        config = copy.deepcopy(CONFIG)
        config["routing"].update(autoImportUnlabeled=True, requireMatch=True, batchSize=10, allowedProjects=["allowed"])
        with patch.dict(sys.modules, {"requests": SimpleNamespace(Session=Orthanc)}), patch.dict(os.environ,
            {"ORTHANC_URL": "http://orthanc", "ORTHANC_READY_LABEL": "ready", "ORTHANC_PROCESSED_LABEL": "done"}), redirect_stdout(io.StringIO()):
            ingest.auto_label(config)
        self.assertEqual(put_urls, ["http://orthanc/studies/stable/labels/ready"])

class SettledProjectTests(unittest.TestCase):
    def test_only_settled_data_provisions_source_group(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        calls = []
        class S3:
            def get_paginator(self, name):
                return self
            def paginate(self, **kwargs):
                prefix = kwargs["Prefix"]
                if "Delimiter" in kwargs:
                    return [{"CommonPrefixes": [{"Prefix": "staged/" + name + "/"} for name in ["p.s.v", "recent.s.v", "empty.s.v"]]}]
                objects = [{"Key": prefix + "__METADATA__.json", "LastModified": now - datetime.timedelta(seconds=600)}]
                if "empty" not in prefix:
                    objects.append({"Key": prefix + "1.Scan/FILES/raw.bin", "LastModified": now if "recent" in prefix else now - datetime.timedelta(seconds=600)})
                return [{"Contents": objects}]
            def get_object(self, **kwargs):
                return {"Body": io.BytesIO(b'{"SourceGroup":"polimeni"}')}
        config = {"ownerUsers": [], "sourceGroupOwner": True}
        with patch.dict(os.environ, {"S3_BUCKET": "bucket", "S3_PREFIX": "staged", "WAIT_PERIOD": "300", "XINGEST_HOST": "http://xnat"}), \
             patch.object(projects, "ensure_project", side_effect=lambda session,server,project,owners: calls.append((project,owners))):
            projects.provision_once(S3(), None, config)
        self.assertEqual(calls, [("p", ["polimeni"])])


class ChartContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        helm = str(Path(os.environ.get("CI_TOOL_DIR", "/tmp/ais-edge-ci-tools")) / "helm")
        if not Path(helm).exists():
            helm = shutil.which("helm")
        if not helm:
            raise unittest.SkipTest("helm unavailable")
        mgmt_values = ROOT / "sites/stanford/values.yaml"
        edge_values = ROOT / "sites/edge-rsl60/values.yaml"
        cls.renders = {}
        for chart, args in [("mgmt", ["-n", "ais-mgmt", "-f", str(mgmt_values)]),
                            ("edge", ["-f", str(mgmt_values), "-f", str(edge_values)])]:
            output = subprocess.check_output([helm, "template", chart, str(ROOT / "charts" / chart),
                        *args, "--set", "domain.mgmtNodeIP=192.0.2.1"], text=True)
            cls.renders[chart] = {(d["kind"], d["metadata"]["name"]): d
                                 for d in yaml.safe_load_all(output) if d}

    def test_external_receiver_and_new_assignment_wiring(self):
        edge = self.renders["edge"]
        self.assertNotIn(("Deployment", "edge-orthanc"), edge)
        self.assertNotIn(("Deployment", "edge-group-orthanc"), edge)
        self.assertNotIn(("Deployment", "edge-assign"), edge)
        workload = edge[("Deployment", "edge-stanford-ingest")]
        self.assertEqual(workload["spec"]["strategy"]["type"], "Recreate")
        container = workload["spec"]["template"]["spec"]["containers"][0]
        env = {entry["name"]: entry for entry in container["env"]}
        self.assertEqual(env["ORTHANC_STORAGE_DIR"]["value"], "/data/db-v6")
        self.assertEqual(env["ORTHANC_PROCESSED_LABEL"]["value"], "xnat-ingest-skip")
        self.assertEqual(env["ORTHANC_USER"]["valueFrom"]["secretKeyRef"]["name"], "orthanc-credentials")
        config = json.loads(edge[("ConfigMap", "edge-stanford-ingest")]["data"]["config.json"])
        self.assertEqual(config["rawUploads"]["allowedProjects"], [])
        policy = edge[("ConfigMap", "edge-data-policy")]["data"]["stages.tsv"]
        self.assertIn("originals.stanfordRawArchive", policy)

    def test_provisioner_bucket_and_credentials_match_uploader(self):
        upload = self.renders["mgmt"][("Deployment", "mgmt-upload-edge-rsl60")]
        containers = {c["name"]: c for c in upload["spec"]["template"]["spec"]["containers"]}
        provision_env = {e["name"]: e for e in containers["project-provisioner"]["env"]}
        upload_env = {e["name"]: e for e in containers["upload"]["env"]}
        self.assertEqual(provision_env["S3_BUCKET"]["value"], "ingest-bucket")
        for name in ("XINGEST_HOST", "XINGEST_USER", "XINGEST_PASS", "S3_ACCESS_KEY", "S3_SECRET_KEY"):
            self.assertEqual(provision_env[name]["valueFrom"], upload_env[name]["valueFrom"])
        reclaimer = self.renders["mgmt"][("CronJob", "mgmt-reclaim-edge-rsl60")]
        env = {e["name"]: e for e in reclaimer["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(env["ARCHIVE_PREFIX"]["value"], "uploaded")
        self.assertEqual(env["DRY_RUN"]["value"], "false")

    def test_token_refresh_role_is_scoped_to_target_and_site(self):
        role = self.renders["mgmt"][("Role", "mgmt-xnat-token-refresh")]
        self.assertEqual(role["rules"][0]["resourceNames"], ["xnat-credentials"])
        self.assertEqual(role["rules"][1]["resourceNames"], ["mgmt-upload-edge-rsl60"])
        job = self.renders["mgmt"][("CronJob", "mgmt-xnat-token-refresh")]
        self.assertEqual(job["spec"]["concurrencyPolicy"], "Forbid")


if __name__ == "__main__":
    unittest.main()
