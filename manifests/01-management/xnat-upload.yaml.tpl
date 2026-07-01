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
          command: ["xnat-ingest", "upload"]
          args:
            - "s3://{{S3_BUCKET}}/staged"
            - "$(XINGEST_HOST)"
            - "--always-include"
            - "all"
            - "--loop"
            - "60"
            - "--wait-period"
            - "{{XNAT_UPLOAD_WAIT_PERIOD}}"
            - "--dont-require-manifest"
            - "--dont-verify-ssl"
            - "--store-credentials"
            - "$(S3_ACCESS_KEY)"
            - "$(S3_SECRET_KEY)"
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
