# =============================================================================
# SeaweedFS — distributed object/file storage with S3 API
# =============================================================================
# Replaces MinIO. Apache 2.0 licensed. S3-compatible API.
#
# Deployment mode: all-in-one (master + volume + filer + S3 in one pod).
# Suitable for single-node MVP. For multi-node scale-out, split into separate
# StatefulSets (see README "Scaling SeaweedFS" section).
#
# Image pinned to 3.99 (last 3.x stable) — avoids the 4.18/4.19 filer memory
# regression (issue #9035) and gives us a known-good baseline. Bump to 4.x
# only after that issue is verified resolved.
#
# The ConfigMap "s3-config" is created separately by 03-deploy-seaweedfs.sh
# (it generates the S3 identities from management.env + edge-nodes.env).
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: seaweedfs
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seaweedfs
  namespace: seaweedfs
  labels:
    app: seaweedfs
spec:
  replicas: 1
  strategy:
    # Recreate (not RollingUpdate) — single hostPath volume can't be shared
    type: Recreate
  selector:
    matchLabels:
      app: seaweedfs
  template:
    metadata:
      labels:
        app: seaweedfs
      # Include the config hash in the pod template so a config change rolls
      # the pod automatically (avoids stale-config drift).
      annotations:
        s3-config-hash: "{{S3_CONFIG_HASH}}"
    spec:
      containers:
        - name: seaweedfs
          image: chrislusf/seaweedfs:3.99
          # `weed server -s3` starts master + volume + filer + S3 in one process
          # -dir         data directory (master/volume/filer all under here)
          # -s3          enable S3 gateway
          # -s3.config   path to IAM identities JSON
          # -s3.port     S3 API port (default 8333)
          # -filer       enable filer (required for S3 to work)
          # -volume.max=0 no upper limit on number of volumes (auto-grow)
          command: ["weed"]
          args:
            - "server"
            - "-dir=/data"
            - "-master.volumeSizeLimitMB=1024"
            - "-volume.max=0"
            - "-filer"
            - "-s3"
            - "-s3.config=/etc/seaweedfs/s3.json"
            - "-s3.port=8333"
            # Built-in Prometheus exposition. Each subsystem exposes its own
            # /metrics endpoint on a dedicated port — Prometheus scrapes all
            # four via the metrics-only ClusterIP Service (defined below).
            # `weed server` exposes ONE Prometheus endpoint that aggregates
            # metrics for master + volume + filer + s3 (subsystem-specific
            # flags like -master.metricsPort don't exist in 3.x).
            - "-metricsPort=9324"
            # NOTE: SeaweedFS already logs S3 requests to stdout by default
            # (one line per PUT/GET with bucket/key/status/bytes). Vector
            # indexes those, giving us a per-object audit trail without
            # instrumenting the application. No extra flag required.
          ports:
            - { containerPort: 8333, name: s3 }
            - { containerPort: 9333, name: master }
            - { containerPort: 8080, name: volume }
            - { containerPort: 8888, name: filer }
            - { containerPort: 9324, name: metrics }
          volumeMounts:
            - name: data
              mountPath: /data
            - name: s3-config
              mountPath: /etc/seaweedfs
          readinessProbe:
            # Master /cluster/status returns 200 + JSON when the cluster is up
            httpGet:
              path: /cluster/status
              port: 9333
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            # TCP probe on S3 port — checks the gateway is accepting connections
            # (HTTP probes against / return 403 without auth, which would fail)
            tcpSocket:
              port: 8333
            initialDelaySeconds: 60
            periodSeconds: 30
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "4Gi"
              cpu: "2000m"
      volumes:
        - name: data
          hostPath:
            path: /data/seaweedfs
            type: DirectoryOrCreate
        - name: s3-config
          configMap:
            name: s3-config
---
apiVersion: v1
kind: Service
metadata:
  name: seaweedfs
  namespace: seaweedfs
spec:
  # ClusterIP only. External access goes through nginx-ingress on
  # https://{{SEAWEEDFS_HOSTNAME}}:443 (TLS-terminated, signed by ais-edge-ca).
  # Master/filer admin UIs are reachable via:
  #   kubectl port-forward -n seaweedfs svc/seaweedfs 9333:9333  # master
  #   kubectl port-forward -n seaweedfs svc/seaweedfs 8888:8888  # filer
  type: ClusterIP
  selector:
    app: seaweedfs
  ports:
    - port: 8333
      targetPort: 8333
      name: s3
    - port: 9333
      targetPort: 9333
      name: master
    - port: 8888
      targetPort: 8888
      name: filer
---
# Separate metrics-only Service so Prometheus discovers four independent
# scrape targets (one per SeaweedFS subsystem). Keeping them off the main
# Service avoids polluting it with internal-only ports.
#
# NOTE on binding: `weed server -metricsPort=9324` listens on the pod IP,
# not 127.0.0.1. `kubectl port-forward` fails because it tries to dial
# inside the pod's loopback, but Prometheus scrapes via the Service IP
# (cluster routing → pod IP) so scraping works fine.
apiVersion: v1
kind: Service
metadata:
  name: seaweedfs-metrics
  namespace: seaweedfs
  labels:
    app: seaweedfs
    release: kube-prometheus-stack
spec:
  type: ClusterIP
  selector:
    app: seaweedfs
  ports:
    - { port: 9324, targetPort: 9324, name: metrics }
# The ServiceMonitor that tells Prometheus to scrape this Service lives
# in manifests/01-management/observability/seaweedfs-servicemonitor.yaml
# and is applied by scripts/02d-install-observability.sh. Keeping it
# out of this file means SeaweedFS (step 03) can install before the
# kube-prometheus-stack CRDs exist — those only land in step 02d.
