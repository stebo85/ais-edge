apiVersion: v1
kind: Namespace
metadata:
  name: xnat-upload
---
apiVersion: v1
kind: Secret
metadata:
  name: xnat-credentials
  namespace: xnat-upload
type: Opaque
stringData:
  server: "{{XNAT_URL}}"
  username: "{{XNAT_USER}}"
  password: "{{XNAT_PASS}}"
---
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: xnat-upload
type: Opaque
stringData:
  access-key: "{{S3_ADMIN_ACCESS_KEY}}"
  secret-key: "{{S3_ADMIN_SECRET_KEY}}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xnat-ingest-upload
  namespace: xnat-upload
  labels:
    app: xnat-ingest
    component: upload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: xnat-ingest
      component: upload
  template:
    metadata:
      labels:
        app: xnat-ingest
        component: upload
    spec:
      containers:
        - name: upload
          # Default points at our fork on ghcr.io with the AIS_LOG_FORMAT=json
          # patch. Override XNAT_INGEST_IMAGE
          # in config/management.env when upstream merges to switch back to
          # ghcr.io/australian-imaging-service/xnat-ingest:latest.
          image: {{XNAT_INGEST_IMAGE}}
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              loop_seconds=60
              wait_period="${XNAT_UPLOAD_WAIT_PERIOD:-300}"

              archive_uploaded_sessions() {
                python3 - "$wait_period" <<'PY'
              import datetime
              import os
              import sys
              import tempfile
              import traceback
              from pathlib import Path

              import boto3
              import xnat
              from xnat_ingest.helpers.remotes import S3SessionListing

              wait_period = int(sys.argv[1])
              bucket = os.environ["S3_BUCKET"]

              def s3_client():
                  return boto3.client(
                      "s3",
                      endpoint_url=os.environ["AWS_ENDPOINT_URL"],
                      aws_access_key_id=os.environ["S3_ACCESS_KEY"],
                      aws_secret_access_key=os.environ["S3_SECRET_KEY"],
                      region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
                  )

              def s3_resource():
                  return boto3.resource(
                      "s3",
                      endpoint_url=os.environ["AWS_ENDPOINT_URL"],
                      aws_access_key_id=os.environ["S3_ACCESS_KEY"],
                      aws_secret_access_key=os.environ["S3_SECRET_KEY"],
                      region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
                  )

              def list_objects(s3, prefix):
                  objects = []
                  paginator = s3.get_paginator("list_objects_v2")
                  for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
                      objects.extend(
                          obj for obj in page.get("Contents", [])
                          if not obj["Key"].endswith("/")
                      )
                  return objects

              def archive_objects(s3, prefix, objects, dest_prefix):
                  for obj in objects:
                      src_key = obj["Key"]
                      dest_key = dest_prefix + src_key[len(prefix):]
                      s3.copy_object(
                          Bucket=bucket,
                          CopySource={"Bucket": bucket, "Key": src_key},
                          Key=dest_key,
                      )

                  for i in range(0, len(objects), 1000):
                      batch = [{"Key": obj["Key"]} for obj in objects[i:i + 1000]]
                      s3.delete_objects(Bucket=bucket, Delete={"Objects": batch})

              def main():
                  now = datetime.datetime.now(datetime.timezone.utc)
                  stamp = now.strftime("%Y%m%dT%H%M%SZ")
                  s3 = s3_client()
                  s3_bucket = s3_resource().Bucket(bucket)

                  paginator = s3.get_paginator("list_objects_v2")
                  session_prefixes = []
                  for page in paginator.paginate(Bucket=bucket, Prefix="staged/", Delimiter="/"):
                      session_prefixes.extend(p["Prefix"] for p in page.get("CommonPrefixes", []))

                  if not session_prefixes:
                      print("archive skip staged/: no staged session prefixes found")
                      return

                  with xnat.connect(
                      os.environ["XINGEST_HOST"],
                      user=os.environ["XINGEST_USER"],
                      password=os.environ["XINGEST_PASS"],
                      verify=False,
                  ) as connection:
                      for prefix in session_prefixes:
                          objects = list_objects(s3, prefix)
                          if not objects:
                              continue
                          latest = max(obj["LastModified"] for obj in objects)
                          age = (now - latest).total_seconds()
                          if age < wait_period:
                              print(f"archive skip {prefix}: newest object age {age:.0f}s < {wait_period}s")
                              continue

                          session_name = prefix.removeprefix("staged/").rstrip("/")
                          rel_objects = [
                              (obj["Key"][len(prefix):].split("/"), None)
                              for obj in objects
                          ]
                          listing = S3SessionListing(
                              name=session_name,
                              bucket=s3_bucket,
                              objects=rel_objects,
                              cache_path=Path(tempfile.gettempdir()) / session_name,
                          )

                          try:
                              ready_to_archive = listing.all_uploaded(connection)
                          except Exception as exc:
                              print(f"archive skip {prefix}: XNAT uploaded check failed: {exc}")
                              continue

                          if not ready_to_archive:
                              print(f"archive skip {prefix}: not all staged resources are present on XNAT")
                              continue

                          dest_prefix = f"uploaded/{stamp}/{session_name}/"
                          archive_objects(s3, prefix, objects, dest_prefix)
                          print(f"archived {prefix} to {dest_prefix} ({len(objects)} objects)")

              try:
                  main()
              except Exception as exc:
                  print(f"archive check failed: {exc}", file=sys.stderr)
                  traceback.print_exc()
              PY
              }

              while true; do
                start_ts=$(date +%s)
                archive_uploaded_sessions
                if xnat-ingest upload "s3://${S3_BUCKET}/staged" "${XINGEST_HOST}" \
                    --always-include all \
                    --wait-period "${wait_period}" \
                    --dont-require-manifest \
                    --dont-verify-ssl \
                    --store-credentials "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}"; then
                  archive_uploaded_sessions
                else
                  echo "xnat-ingest upload failed before completing the staged scan; archiving only sessions already complete in XNAT" >&2
                  archive_uploaded_sessions
                fi

                elapsed=$(( $(date +%s) - start_ts ))
                sleep_for=$(( loop_seconds - elapsed ))
                [ "$sleep_for" -gt 0 ] || sleep_for=0
                echo "xnat-upload loop took ${elapsed}s, sleeping ${sleep_for}s"
                sleep "$sleep_for"
              done
          env:
            - name: XINGEST_HOST
              valueFrom:
                secretKeyRef:
                  name: xnat-credentials
                  key: server
            - name: XINGEST_USER
              valueFrom:
                secretKeyRef:
                  name: xnat-credentials
                  key: username
            - name: XINGEST_PASS
              valueFrom:
                secretKeyRef:
                  name: xnat-credentials
                  key: password
            - name: S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-credentials
                  key: access-key
            - name: S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-credentials
                  key: secret-key
            - name: S3_BUCKET
              value: "{{S3_BUCKET}}"
            - name: XNAT_UPLOAD_WAIT_PERIOD
              value: "{{XNAT_UPLOAD_WAIT_PERIOD}}"
            # Point boto3 at the in-cluster SeaweedFS service
            - name: AWS_ENDPOINT_URL
              value: "http://seaweedfs.seaweedfs.svc.cluster.local:8333"
            - name: AWS_DEFAULT_REGION
              value: "us-east-1"
            # Emit one JSON object per log line so Vector indexes
            # ts/level/logger/message without regex parsing.
            - name: AIS_LOG_FORMAT
              value: "json"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: xnat-token-refresh
  namespace: xnat-upload
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: xnat-token-refresh
  namespace: xnat-upload
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["xnat-credentials"]
    verbs: ["get", "patch", "update"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    resourceNames: ["xnat-ingest-upload"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: xnat-token-refresh
  namespace: xnat-upload
subjects:
  - kind: ServiceAccount
    name: xnat-token-refresh
    namespace: xnat-upload
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: xnat-token-refresh
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: xnat-token-refresh
  namespace: xnat-upload
spec:
  schedule: "0 */12 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: xnat-token-refresh
          restartPolicy: Never
          containers:
            - name: refresh
              image: {{XNAT_INGEST_IMAGE}}
              imagePullPolicy: IfNotPresent
              env:
                - name: POD_NAMESPACE
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.namespace
                - name: XNAT_SOURCE_SERVER
                  valueFrom:
                    secretKeyRef:
                      name: xnat-token-source
                      key: server
                - name: XNAT_SOURCE_USER
                  valueFrom:
                    secretKeyRef:
                      name: xnat-token-source
                      key: username
                - name: XNAT_SOURCE_PASS
                  valueFrom:
                    secretKeyRef:
                      name: xnat-token-source
                      key: password
                - name: XNAT_UPLOAD_SERVER
                  value: "{{XNAT_URL}}"
              command: ["python3", "-c"]
              args:
                - |
                  import base64
                  import datetime
                  import json
                  import os
                  import ssl
                  import urllib.request

                  ns = os.environ.get("POD_NAMESPACE", "xnat-upload")
                  source_server = os.environ["XNAT_SOURCE_SERVER"].rstrip("/")
                  upload_server = os.environ.get("XNAT_UPLOAD_SERVER", source_server).rstrip("/")
                  source_user = os.environ["XNAT_SOURCE_USER"]
                  source_pass = os.environ["XNAT_SOURCE_PASS"]

                  basic = base64.b64encode(f"{source_user}:{source_pass}".encode()).decode()
                  req = urllib.request.Request(f"{source_server}/data/services/tokens/issue?format=json")
                  req.add_header("Authorization", f"Basic {basic}")
                  with urllib.request.urlopen(req, timeout=30) as resp:
                      issued = json.load(resp)

                  refreshed_at = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
                  secret_patch = {
                      "metadata": {
                          "annotations": {
                              "ais-edge/xnat-token-expires": str(issued.get("estimatedExpirationTime", "unknown")),
                              "ais-edge/xnat-token-refreshed-at": refreshed_at,
                          }
                      },
                      "data": {
                          "server": base64.b64encode(upload_server.encode()).decode(),
                          "username": base64.b64encode(issued["alias"].encode()).decode(),
                          "password": base64.b64encode(issued["secret"].encode()).decode(),
                      },
                  }
                  deploy_patch = {
                      "spec": {
                          "template": {
                              "metadata": {
                                  "annotations": {
                                      "ais-edge/xnat-token-refreshed-at": refreshed_at,
                                  }
                              }
                          }
                      }
                  }

                  with open("/var/run/secrets/kubernetes.io/serviceaccount/token", "r", encoding="utf-8") as f:
                      bearer = f.read().strip()
                  context = ssl.create_default_context(
                      cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
                  )

                  def patch(path, body):
                      request = urllib.request.Request(
                          f"https://kubernetes.default.svc{path}",
                          data=json.dumps(body).encode(),
                          method="PATCH",
                      )
                      request.add_header("Authorization", f"Bearer {bearer}")
                      request.add_header("Content-Type", "application/merge-patch+json")
                      with urllib.request.urlopen(request, timeout=30, context=context) as resp:
                          resp.read()

                  patch(f"/api/v1/namespaces/{ns}/secrets/xnat-credentials", secret_patch)
                  patch(f"/apis/apps/v1/namespaces/{ns}/deployments/xnat-ingest-upload", deploy_patch)
                  print(f"refreshed xnat alias token, expires={secret_patch['metadata']['annotations']['ais-edge/xnat-token-expires']}")
