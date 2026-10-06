"""Provision settled Stanford sessions and verify existing users' project ownership."""
import datetime
import json
import os
import time
import urllib.parse
import xml.etree.ElementTree as ET


def log(event, **fields):
    print(json.dumps({"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      "component": "project-provisioner", "event": event, **fields}), flush=True)


def rows(payload):
    if isinstance(payload, list):
        return payload
    return payload.get("ResultSet", {}).get("Result", [])


def ensure_project(session, server, project, owners):
    """Do not invent accounts; verify each requested Owner after the PUT."""
    project_url = server + "/data/projects/" + urllib.parse.quote(project, safe="")
    response = session.get(project_url + "?format=json", timeout=30)
    if response.status_code == 404:
        # XNAT's documented create endpoint accepts a Project XML document.
        # https://wiki.xnat.org/xnat-api/project-api
        namespace = "http://nrg.wustl.edu/xnat"
        ET.register_namespace("xnat", namespace)
        document = ET.Element("{" + namespace + "}Project", {"ID": project, "secondary_ID": project})
        ET.SubElement(document, "{" + namespace + "}name").text = project
        ET.SubElement(document, "{" + namespace + "}description").text = "AIS Edge project"
        response = session.post(server + "/data/projects", data=ET.tostring(document),
                                headers={"Content-Type": "application/xml"}, timeout=30)
        # Another edge may have created this project since our GET.
        if response.status_code != 409:
            response.raise_for_status()
        log("project_created", project=project)
    else:
        response.raise_for_status()
    response = session.get(project_url + "/users?format=json", timeout=30)
    response.raise_for_status()
    existing = rows(response.json())
    known_users = None
    for owner in sorted(set(owners)):
        if any(str(row.get("login", "")).casefold() == owner.casefold() and
               str(row.get("displayname", "")).casefold() == "owners" for row in existing):
            continue
        try:
            # Verify the account first. An unknown EMAIL on the membership PUT
            # would send an invitation rather than just defer ownership.
            if known_users is None:
                response = session.get(server + "/data/users?format=json", timeout=30)
                response.raise_for_status()
                known_users = {str(row.get("login") or row.get("username") or "").casefold()
                               for row in rows(response.json())}
            if owner.casefold() not in known_users:
                raise RuntimeError("Existing XNAT account not found")
            response = session.put(project_url + "/users/Owners/" + urllib.parse.quote(owner, safe=""), timeout=30)
            response.raise_for_status()
            response = session.get(project_url + "/users?format=json", timeout=30)
            response.raise_for_status()
            if not any(str(row.get("login", "")).casefold() == owner.casefold() and
                       str(row.get("displayname", "")).casefold() == "owners" for row in rows(response.json())):
                raise RuntimeError("XNAT did not confirm Owner membership")
            log("project_owner_added", project=project, user=owner)
        except Exception as exc:
            # A missing user does not prevent other projects or owners being synced.
            log("project_owner_deferred", project=project, user=owner, message=str(exc))


def provision_once(s3, session, config):
    bucket = os.environ["S3_BUCKET"]
    prefix = os.environ["S3_PREFIX"].rstrip("/") + "/"
    now = datetime.datetime.now(datetime.timezone.utc)
    server = os.environ["XINGEST_HOST"].rstrip("/")
    defaults = config["ownerUsers"]
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix, Delimiter="/"):
        for entry in page.get("CommonPrefixes", []):
            session_prefix = entry["Prefix"]
            name = session_prefix[len(prefix):].rstrip("/")
            if name.startswith(("__", ".")) or len(name.split(".")) not in (3, 4):
                continue
            objects = []
            for contents in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=session_prefix):
                objects.extend(contents.get("Contents", []))
            if not objects or (now - max(obj["LastModified"] for obj in objects)).total_seconds() < int(os.environ["WAIT_PERIOD"]):
                continue
            metadata_names = {"__METADATA__.json", "__MANIFEST__.json", "MANIFEST.json", "METADATA.yaml"}
            if not any(obj["Key"].rsplit("/", 1)[-1] not in metadata_names and not obj["Key"].endswith("/") for obj in objects):
                continue
            project = name.split(".")[0]
            owners = list(defaults)
            key = session_prefix + "__METADATA__.json"
            if config["sourceGroupOwner"] and any(obj["Key"] == key for obj in objects):
                metadata = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
                if metadata.get("SourceGroup"):
                    owners.append(str(metadata["SourceGroup"]))
            try:
                ensure_project(session, server, project, owners)
            except Exception as exc:
                log("project_provision_failed", project=project, message=str(exc))
    # Stanford's configured administrators belong to all existing projects too.
    if defaults:
        response = session.get(server + "/data/projects?format=json", timeout=30)
        response.raise_for_status()
        for row in rows(response.json()):
            project = row.get("ID") or row.get("id")
            if project:
                ensure_project(session, server, str(project), defaults)


def main():
    import boto3
    import requests
    config = json.loads(os.environ["PROJECT_PROVISIONING"])
    s3 = boto3.client("s3", endpoint_url=os.environ["AWS_ENDPOINT_URL"],
                      aws_access_key_id=os.environ["S3_ACCESS_KEY"],
                      aws_secret_access_key=os.environ["S3_SECRET_KEY"],
                      region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    session = requests.Session()
    session.auth = (os.environ["XINGEST_USER"], os.environ["XINGEST_PASS"])
    session.verify = os.environ.get("XNAT_VERIFY_SSL", "true") == "true"
    while True:
        try:
            provision_once(s3, session, config)
        except Exception as exc:
            log("project_provision_failed", message=str(exc))
        time.sleep(int(os.environ.get("PROVISION_INTERVAL", "60")))


if __name__ == "__main__":
    main()
