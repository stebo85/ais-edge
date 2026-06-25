# Orthanc DICOM receiver + label hook.
#
# Role at the edge:
#   1. DIMSE SCP on host port 4242 (AET=AISEDGE) — modalities push studies here.
#   2. Lua OnStableStudy (after StableAge=30s silence) PUTs the
#      `xnat-ingest-ready` label on the study.
#   3. xnat-ingest sort REST-pulls labelled studies and hardlinks instances
#      from /data/orthanc-storage into /data/staging.
#
# ConfigMaps (orthanc-config, orthanc-scripts) are created by
# scripts/07c-deploy-edge-orthanc.sh via `kubectl create configmap --from-file`
# so the source-of-truth lives in config/orthanc/ and we don't have to
# YAML-indent the file contents.
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orthanc
  namespace: xnat-ingest
  labels:
    app: orthanc
    component: dicom-receiver
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: orthanc
      component: dicom-receiver
  template:
    metadata:
      labels:
        app: orthanc
        component: dicom-receiver
    spec:
      containers:
        - name: orthanc
          image: {{ORTHANC_IMAGE}}
          args: ["/etc/orthanc"]
          ports:
            - name: dicom
              containerPort: 4242
              hostPort: 4242    # exposed on edge node IP for local-LAN modalities
            - name: http
              containerPort: 8042
          env:
            - name: AIS_INGEST_READY_LABEL
              value: xnat-ingest-ready
          volumeMounts:
            - name: config
              mountPath: /etc/orthanc/orthanc.json
              subPath: orthanc.json
              readOnly: true
            - name: scripts
              mountPath: /etc/orthanc/scripts
              readOnly: true
            # Shared with xnat-ingest sort. Same hostPath on both pods so
            # hardlinks from /data/orthanc-storage to /data/staging resolve
            # to the same inode (cross-fs hardlink would EXDEV).
            - name: data
              mountPath: /data
      volumes:
        - name: config
          configMap:
            name: orthanc-config
        - name: scripts
          configMap:
            name: orthanc-scripts
            defaultMode: 0755
        - name: data
          hostPath:
            path: /data/xnat-ingest
            type: DirectoryOrCreate
---
# ClusterIP for sort to reach Orthanc's REST API. DICOM port (4242) is
# exposed via hostPort on the Deployment, not via this Service.
apiVersion: v1
kind: Service
metadata:
  name: orthanc
  namespace: xnat-ingest
spec:
  type: ClusterIP
  selector:
    app: orthanc
    component: dicom-receiver
  ports:
    - name: http
      port: 8042
      targetPort: 8042
