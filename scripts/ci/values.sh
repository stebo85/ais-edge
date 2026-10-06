#!/usr/bin/env bash
# =============================================================================
# The values matrix — the single definition of every case CI renders.
# =============================================================================
# Sourced by scripts/ci/render.sh and scripts/ci/negative.sh. Running it
# directly just writes the values files and lists the cases, which is useful
# for reproducing one case by hand:
#
#   scripts/ci/values.sh
#   helm template mgmt charts/mgmt -f $CI_VALUES_DIR/mgmt-base.yaml \
#                                  -f $CI_VALUES_DIR/mgmt-two-edges.yaml
#
# WHY THE VALUES LIVE HERE AND NOT IN charts/*/ci-values.yaml
# A values file next to the chart looks like a supported configuration and
# gets copied into a site. These are test fixtures; they belong to the test.
#
# NOTHING IN HERE IS A CREDENTIAL. Every case references Secrets by name only,
# exactly as the charts require. If a future case appears to need a password,
# the chart has a bug, not the fixture.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/ci/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

V="$CI_VALUES_DIR"
mkdir -p "$V"

# =============================================================================
# Base values — the minimum each chart needs to render at all.
# =============================================================================
# These are NOT "chart defaults": both charts deliberately refuse to render
# with several keys unset (domain, clusterLabel, the S3 bucket, the deid
# policy acknowledgement), because a default for any of them would be a wrong
# answer that installs cleanly. The base file supplies exactly those, and
# nothing else, so `<chart>-defaults` really is the shipped configuration plus
# the operator's mandatory answers.

cat >"$V/mgmt-base.yaml" <<'EOF'
domain:
  internal: ci.198-51-100-10.nip.io
  mgmtNodeIP: "198.51.100.10"
observability:
  alerting:
    emailFrom: ais-edge-ci@example.invalid
    emailTo: ops@example.invalid
    smtpHost: smtp.example.invalid
edges:
  # exposure: nodePort with EXPLICIT ports, which is what the chart requires —
  # the ports are deliberately not derived from list position.
  - name: edge-alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30132
EOF

cat >"$V/edge-base.yaml" <<'EOF'
clusterLabel: edge-alpha
hostAliases:
  enabled: true
  mgmtNodeIP: "198.51.100.10"
  hostnames: ["seaweedfs.ci.198-51-100-10.nip.io", "loki.ci.198-51-100-10.nip.io"]
upload:
  mode: s3
  s3:
    endpoint: "https://seaweedfs.ci.198-51-100-10.nip.io"
    bucket: ingest-edge-alpha
    caBundleSecret: ca-bundle
deid:
  engine: orthanc
  policyReviewed: true
orthanc:
  deid:
    aetMap:
      SIEMENS_3T: {project: CI_RESEARCH}
    profile:
      DeidMode: "Basic"
      Force: true
      RemovePrivateTags: true
      Keep: ["StudyInstanceUID", "SeriesInstanceUID"]
      Replace:
        PatientName: "ANON"
EOF

# =============================================================================
# POSITIVE overlays — combinations that must RENDER.
# =============================================================================

# -- mgmt ---------------------------------------------------------------------

# A second site. Every per-edge object (Cluster, S3 identity, bucket, uploader
# Deployment, reclaimer CronJob, Ingress host) is ranged from this list, so one
# entry never exercises the naming that two entries collide on.
cat >"$V/mgmt-two-edges.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30132
  - name: edge-beta
    nodeIP: 198.51.100.22
    s3SecretRef: edge-beta-s3
    exposure: nodePort
    apiNodePort: 30444
    konnectivityNodePort: 30133
EOF

# DataPolicyReporterSilent is keyed on `edges`. An edge that runs without a
# reporter opts out; with none left the rule must not render at all (an empty
# inventory is not valid LogQL). runtime-templates.sh checks both cases.
cat >"$V/mgmt-reporter-optout.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30132
  - name: edge-beta
    nodeIP: 198.51.100.22
    s3SecretRef: edge-beta-s3
    exposure: nodePort
    apiNodePort: 30444
    konnectivityNodePort: 30133
    dataPolicyReporter: false
EOF
cat >"$V/mgmt-reporter-optout-all.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30132
    dataPolicyReporter: false
EOF
# With no reporting edge the rule is dropped and reporterSilentAfter is unused,
# so a value the guard would refuse must still render. The guard applies only
# where DataPolicyReporterSilent exists (neg-mgmt-reporter-silent-*).
printf 'dataPolicy:\n  reporterSilentAfter: never\n' >"$V/mgmt-reporter-silent-never.yaml"
# ReclaimerNotSucceeding: a slowed schedule with alertAfter raised with it must
# render (promtool.sh checks its threshold is 13h in seconds), and with
# reclaim: never there is no reclaimer, so no rule and no guard to trip.
printf 'dataPolicy:\n  derived:\n    s3Staged:\n      schedule: "17 */6 * * *"\n      alertAfter: 13h\n' >"$V/mgmt-reclaimer-six-hourly.yaml"
printf 'dataPolicy:\n  derived:\n    s3Staged:\n      reclaim: never\n      alertAfter: never\n' >"$V/mgmt-reclaimer-off.yaml"

# The other exposure mode: ClusterIP behind the ssl-passthrough Ingress, no
# cluster-wide port to track. Both modes have to render, because the chart
# supports a fleet with one site on each during a migration.
cat >"$V/mgmt-sni-exposure.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: sni
  - name: edge-beta
    nodeIP: 198.51.100.22
    s3SecretRef: edge-beta-s3
    exposure: nodePort
    apiNodePort: 30444
    konnectivityNodePort: 30133
EOF

cat >"$V/mgmt-observability-off.yaml" <<'EOF'
observability:
  enabled: false
EOF

# dataPolicy on and dryRun off: the reclaimer's real code path.
cat >"$V/mgmt-datapolicy-on.yaml" <<'EOF'
dataPolicy:
  enabled: true
  dryRun: false
EOF

# Leading zeros must read as base 10. sprig's int64 read them as octal, so
# "010d" rendered 691200 (8 days) and "08d" rendered 0, which puts
# QuarantinedDataUnresolved on every quarantined study at once.
# runtime-templates.sh asserts the thresholds that reach the Loki rules.
cat >"$V/mgmt-duration-base10.yaml" <<'EOF'
dataPolicy:
  stageAgeAlertAfter: "010d"
  originals:
    quarantine:
      alertAfter: "08d"
EOF

# A management node with no SeaweedFS: Loki on a filesystem PVC, no uploader,
# no reclaimer. This is the tier-1 shape, and it is the case where the
# loki.storage / seaweedfs.enabled coupling has to hold.
cat >"$V/mgmt-no-seaweedfs.yaml" <<'EOF'
seaweedfs:
  enabled: false
xnatUpload:
  enabled: false
observability:
  loki:
    storage: filesystem
dataPolicy:
  derived:
    s3Staged:
      reclaim: never
EOF

# The shared-bucket layout, kept only so sites can migrate one at a time.
cat >"$V/mgmt-shared-bucket.yaml" <<'EOF'
seaweedfs:
  perSiteBuckets: false
EOF

# Let's Encrypt staging with a DNS-01 solver. Exercises the ACME ClusterIssuer
# branch, which is otherwise never rendered.
# THE SHIPPED CLOUD SITE ITSELF. Not a hand-written fixture: sites/example-cloud
# is what an operator copies, so if it stops rendering CI is what should notice.
cp "$REPO_ROOT/sites/example-cloud/values.yaml" "$V/mgmt-cloud.yaml"

# mTLS on the S3 upload path, FULLY ROLLED OUT — both switches on and the
# certSync entry that carries the certificate in. This is the only case that
# renders the auth-tls-* annotations on the SeaweedFS Ingress, the S3 client CA
# anchor and the per-edge <edge>-s3-client Certificates; without it that whole
# path ships never having been rendered once.
#
# certSync.secrets is restated in FULL because Helm replaces lists rather than
# merging them: naming only the new entry would drop the Loki client cert entry
# and trip that guard first.
cat >"$V/mgmt-s3-mtls.yaml" <<'EOF'
seaweedfs:
  ingress:
    clientCerts:
      issue: true
      require: true
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: xnat-ingest, name: ca-bundle, type: Opaque}
    - source:
        namespace: ais-mgmt
        name: "<edge>-loki-client"
        keys: {tls.crt: tls.crt, tls.key: tls.key}
      destination: {namespace: xnat-ingest, name: loki-push-client-tls, type: kubernetes.io/tls}
    - source:
        namespace: ais-mgmt
        name: "<edge>-s3-client"
        keys: {tls.crt: tls.crt, tls.key: tls.key}
      destination: {namespace: xnat-ingest, name: s3-client-tls, type: kubernetes.io/tls}
EOF

# Step 1 of the rollout, layered ON TOP of the case above: certificates issued
# and delivered, nothing verifying them yet. That is the state a fleet sits in
# between `issue` and `require` — the window in which the operator confirms the
# Secret landed on every site — so it has to render too. The Ingress must come
# out with NO auth-tls-* annotations here while the Certificates are present.
cat >"$V/mgmt-s3-mtls-issue-only.yaml" <<'EOF'
seaweedfs:
  ingress:
    clientCerts:
      require: false
EOF

cat >"$V/mgmt-letsencrypt.yaml" <<'EOF'
certManager:
  issuer: letsencrypt-staging
  acme:
    email: ci@example.invalid
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    dns01Solver:
      route53:
        region: ap-southeast-2
        accessKeyIDSecretRef: {name: route53-credentials, key: access-key-id}
        secretAccessKeySecretRef: {name: route53-credentials, key: secret-access-key}
EOF

# -- edge ---------------------------------------------------------------------

# Tier-1: no management plane, no S3, no CA plumbing.
cat >"$V/edge-upload-direct.yaml" <<'EOF'
upload:
  mode: direct
observability:
  enabled: false
EOF

cat >"$V/edge-observability-on.yaml" <<'EOF'
observability:
  enabled: true
  loki:
    endpoint: "https://loki.ci.198-51-100-10.nip.io"
    clientCertSecret: loki-push-client-tls
    caBundleSecret: ca-bundle
EOF

# The edge half of S3 mTLS: mount the client certificate and present it. The
# only case that renders RCLONE_CLIENT_CERT / RCLONE_CLIENT_KEY and the
# s3-client volume, and the one that proves they are NOT coupled to
# caBundleSecret — both are set here, and edge-cloud-s3-mtls below sets only
# this one.
cat >"$V/edge-s3-mtls.yaml" <<'EOF'
upload:
  s3:
    requireClientCert: true
    clientCertSecret: s3-client-tls
EOF

# CLOUD NUANCE, and the reason the two keys are independent: on cloud the
# SeaweedFS server certificate can come from a public CA that is already in the
# image's trust store, so caBundleSecret is legitimately EMPTY — while our own
# client identity still comes from the fleet CA via cert-sync. This case would
# not render if the client cert were nested inside the CA-bundle branch.
# The endpoint is http:// because the https guard requires a CA bundle; what is
# under test is that the client-certificate mount survives an empty
# caBundleSecret, not the endpoint scheme.
cat >"$V/edge-s3-mtls-no-cabundle.yaml" <<'EOF'
upload:
  s3:
    endpoint: "http://mgmt-seaweedfs.ais-mgmt.svc.cluster.local:8333"
    caBundleSecret: ""
    requireClientCert: true
EOF

cat >"$V/edge-samba-on.yaml" <<'EOF'
samba:
  enabled: true
  existingSecret: samba-credentials
EOF

# fileDrop with reclaim left at 'never' — the only combination the chart
# permits, and the point of the guard the negative case below covers.
cat >"$V/edge-filedrop-on.yaml" <<'EOF'
ingest:
  fileDrop:
    enabled: true
EOF

cat >"$V/edge-datapolicy-on.yaml" <<'EOF'
dataPolicy:
  enabled: true
  dryRun: false
EOF

# The edge half of the base-10 case. Before the fix these rendered 691200,
# 0 ("expire immediately") and 3712. "0000007200" is also exactly 10 digits,
# the most the parser accepts, and takes the plain-seconds branch.
# runtime-templates.sh asserts the numbers in stages.tsv.
cat >"$V/edge-duration-base10.yaml" <<'EOF'
dataPolicy:
  originals:
    quarantine:
      alertAfter: "0000007200"
  derived:
    assigned:
      minAge: "010d"
    orthancStorage:
      minAge: "08d"
EOF

# De-identification off. One key now, and the group label needs no clearing:
# the chart derives it from the engine, so it cannot be left dangling.
# policyReviewed is what acknowledges that identifiable data would reach XNAT.
cat >"$V/edge-deid-off.yaml" <<'EOF'
deid:
  engine: none
  policyReviewed: true
EOF

cat >"$V/edge-cloud.yaml" <<'EOF'
topology: cloud
hostAliases:
  enabled: false
EOF

# Slack configured. The ONLY case that renders the Slack half of the
# Alertmanager config: slackWebhookSecretRef switches the severity=info and
# severity=critical routes onto the Slack receivers AND splices
# files/alertmanager-slack-receivers.yaml in. Without a case here that branch
# ships untested — which is how every info alert came to be routed at a
# webhook file no Secret ever provided.
#
# alertmanagerSpec.secrets has to be restated in full: the guard in
# templates/observability.yaml requires the webhook Secret to be mounted, and
# Helm REPLACES lists rather than merging them, so naming only the new one
# would drop alertmanager-smtp and trip the SMTP guard first.
cat >"$V/mgmt-slack.yaml" <<'EOF'
observability:
  alerting:
    slackWebhookSecretRef: alertmanager-slack
kube-prometheus-stack:
  alertmanager:
    alertmanagerSpec:
      secrets:
        - alertmanager-smtp
        - alertmanager-slack
EOF

# =============================================================================
# NEGATIVE overlays — each one injects exactly ONE defect.
# =============================================================================
# Each is applied on top of a base that is already in the positive matrix, so
# the only thing that can make the render fail is the injected defect. The
# expected-substring in the case table is what turns "it failed" into "it
# failed for the reason we claim", which is the difference between a test and
# a coincidence.
#
# `key: null` rather than `key: {}` where a map has to be CLEARED: Helm
# coalesces maps, so an empty map in an overlay leaves the base value intact
# and the case would silently pass for the wrong reason.

# -- mgmt ---------------------------------------------------------------------
printf 'domain:\n  internal: ""\n'                        >"$V/neg-mgmt-no-domain.yaml"
printf 'domain:\n  mgmtNodeIP: ""\n'                      >"$V/neg-mgmt-no-nodeip.yaml"

cat >"$V/neg-mgmt-duplicate-edges.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: sni
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: sni
EOF

cat >"$V/neg-mgmt-edge-no-name.yaml" <<'EOF'
edges:
  - nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: sni
EOF

cat >"$V/neg-mgmt-edge-no-s3secret.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: 198.51.100.21
    exposure: sni
EOF

# An edge name that is not a DNS-1123 label. The `.` is the point: the name is
# interpolated into the auth-tls-match-cn regex on the Loki push Ingress, where
# a metacharacter WIDENS what is accepted instead of erroring.
cat >"$V/neg-mgmt-edge-name-not-label.yaml" <<'EOF'
edges:
  - name: edge.alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: sni
EOF

# ---- k0smotron exposure ------------------------------------------------------
# The bug these guard against: a NodePort derived from an edge's POSITION in
# the list moves to another site's number when the list is reordered, while
# helm.sh/resource-policy: keep leaves the old Service holding the old one.
cat >"$V/neg-mgmt-edge-no-nodeport.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
EOF

cat >"$V/neg-mgmt-nodeport-out-of-range.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 8443
    konnectivityNodePort: 30132
EOF

cat >"$V/neg-mgmt-nodeport-collision.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30132
  - name: edge-beta
    s3SecretRef: edge-beta-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30133
EOF

cat >"$V/neg-mgmt-bad-exposure.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: loadBalancer
EOF

cat >"$V/neg-mgmt-sni-with-nodeport.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: sni
    apiNodePort: 30443
EOF

# Two sites claiming one hostname: nginx routes by SNI, so one site's workers
# would reach the other site's control plane.
cat >"$V/neg-mgmt-duplicate-hostname.yaml" <<'EOF'
edges:
  - name: edge-alpha
    s3SecretRef: edge-alpha-s3
    exposure: sni
    apiHost: k0s.ci.198-51-100-10.nip.io
  - name: edge-beta
    s3SecretRef: edge-beta-s3
    exposure: sni
    apiHost: k0s.ci.198-51-100-10.nip.io
EOF

# The fleet-wide hostnames that produced the collision in the first place.
cat >"$V/neg-mgmt-fleetwide-hostnames.yaml" <<'EOF'
hostnames:
  k0sApi: k0s.ci.198-51-100-10.nip.io
EOF

# The vector subchart's customConfig is not templated by Helm, so the Loki
# address in it is a literal nothing keeps in step with the release. Both
# halves of the drift are covered: the namespace it names, and the Service.
cat >"$V/neg-mgmt-vector-loki-wrong-ns.yaml" <<'EOF'
vector:
  customConfig:
    sinks:
      loki:
        endpoint: http://mgmt-loki.observability.svc.cluster.local:3100
EOF

cat >"$V/neg-mgmt-vector-loki-wrong-svc.yaml" <<'EOF'
vector:
  customConfig:
    sinks:
      loki:
        endpoint: http://loki:3100
EOF

cat >"$V/neg-mgmt-loki-s3-no-seaweedfs.yaml" <<'EOF'
seaweedfs:
  enabled: false
observability:
  loki:
    storage: s3
EOF

# XNATResourceIncompleteAndStuck's threshold is derived from this value, so a
# non-positive loop is a division by zero at render time, not just a slow poll.
printf 'xnatUpload:\n  loop: 0\n'                          >"$V/neg-mgmt-upload-loop-zero.yaml"
# DataPolicyReporterSilent's LogQL lookback. forever/never/empty parse to -1,
# which Loki rejects as a duration (and the rule group with it); 0 and anything
# under a minute are refused too. Codex reproduced the rejection on Loki 3.6.8.
for w in forever never '""' 0 30s; do
  n="$(printf '%s' "$w" | tr -d '"')"; n="${n:-empty}"
  printf 'dataPolicy:\n  reporterSilentAfter: %s\n' "$w" >"$V/neg-mgmt-reporter-silent-$n.yaml"
done
# ReclaimerNotSucceeding's alertAfter must exceed 2 x the schedule period +
# deadlineSeconds (one failed run then a slow success goes that long).
printf 'dataPolicy:\n  derived:\n    s3Staged:\n      alertAfter: 1h\n' >"$V/neg-mgmt-reclaimer-alert-after-1h.yaml"
printf 'dataPolicy:\n  derived:\n    s3Staged:\n      schedule: "17 */6 * * *"\n' >"$V/neg-mgmt-reclaimer-six-hourly-3h.yaml"
printf 'dataPolicy:\n  derived:\n    s3Staged:\n      schedule: "*/30 * * * *"\n      alertAfter: 1h\n' >"$V/neg-mgmt-reclaimer-every-30m-1h.yaml"
for w in forever never '""' 0 30m; do
  n="$(printf '%s' "$w" | tr -d '"')"; n="${n:-empty}"
  printf 'dataPolicy:\n  derived:\n    s3Staged:\n      alertAfter: %s\n' "$w" >"$V/neg-mgmt-reclaimer-alert-after-$n.yaml"
done
printf 'observability:\n  alerting:\n    emailTo: ""\n'   >"$V/neg-mgmt-no-emailto.yaml"
printf 'observability:\n  alerting:\n    smtpHost: ""\n'  >"$V/neg-mgmt-no-smtphost.yaml"
printf 'xnatUpload:\n  xnatSecretRef: ""\n'               >"$V/neg-mgmt-no-xnatsecret.yaml"
printf 'k0smotron:\n  persistence:\n    type: emptyDir\n' >"$V/neg-mgmt-k0smotron-emptydir.yaml"

cat >"$V/neg-mgmt-le-no-email.yaml" <<'EOF'
certManager:
  issuer: letsencrypt-prod
  acme:
    email: ""
    dns01Solver:
      route53: {region: ap-southeast-2}
EOF

cat >"$V/neg-mgmt-le-no-dns01.yaml" <<'EOF'
certManager:
  issuer: letsencrypt-prod
  acme:
    email: ci@example.invalid
    dns01Solver: null
EOF

# Staging issuer still pointed at the production ACME directory: the case
# where "I am testing" spends the real rate limit.
cat >"$V/neg-mgmt-le-staging-prod-url.yaml" <<'EOF'
certManager:
  issuer: letsencrypt-staging
  acme:
    email: ci@example.invalid
    server: https://acme-v02.api.letsencrypt.org/directory
    dns01Solver:
      route53: {region: ap-southeast-2}
EOF

printf 'certManager:\n  ca:\n    commonName: "Some Other CA"\n' >"$V/neg-mgmt-ca-commonname.yaml"
printf 'certManager:\n  ca:\n    mode: bogus\n'                 >"$V/neg-mgmt-ca-bad-mode.yaml"
printf 'certManager:\n  clusterResourceNamespace: ""\n'         >"$V/neg-mgmt-no-cm-namespace.yaml"

cat >"$V/neg-mgmt-ca-intermediate-no-secret.yaml" <<'EOF'
certManager:
  ca:
    mode: intermediate
    intermediate:
      secretRef: ""
EOF

printf 'ingressNginx:\n  sslPassthrough: false\n'         >"$V/neg-mgmt-no-sslpassthrough.yaml"

cat >"$V/neg-mgmt-reclaimer-no-uploader.yaml" <<'EOF'
xnatUpload:
  enabled: false
EOF

cat >"$V/neg-mgmt-reclaimer-no-seaweedfs.yaml" <<'EOF'
seaweedfs:
  enabled: false
observability:
  loki:
    storage: filesystem
EOF

# The subchart-coupling guards. Each of these is a value that looks harmless
# on its own and silently disconnects a whole subsystem.
cat >"$V/neg-mgmt-am-configsecret.yaml" <<'EOF'
kube-prometheus-stack:
  alertmanager:
    alertmanagerSpec:
      configSecret: some-other-secret
EOF

cat >"$V/neg-mgmt-am-smtp-not-mounted.yaml" <<'EOF'
kube-prometheus-stack:
  alertmanager:
    alertmanagerSpec:
      secrets: null
EOF

cat >"$V/neg-mgmt-grafana-secret-mismatch.yaml" <<'EOF'
kube-prometheus-stack:
  grafana:
    admin:
      existingSecret: not-the-one-the-chart-creates
EOF

cat >"$V/neg-mgmt-loki-ruler-not-mounted.yaml" <<'EOF'
loki:
  singleBinary:
    extraVolumes: null
EOF

# The landmine from the imperative installer: a rule selector hardcoded to a
# release name that is no longer ours.
cat >"$V/neg-mgmt-prom-release-label.yaml" <<'EOF'
observability:
  prometheusReleaseLabel: kube-prometheus-stack
EOF

# ---- cert-sync ---------------------------------------------------------------
# cert-sync is the job that stops an edge from silently holding an expired
# certificate after cert-manager renews it on the management side. Its guards
# are therefore guards on the thing that makes the renewal visible at all, and
# two of them (the CA namespace and the tls.key refusal) are the difference
# between "syncs nothing forever" and "distributes the fleet CA private key".


# POSITIVE counterpart: Clusters managed outside the chart is a supported and
# correct configuration, and it is the one stream-2-ab-dev actually runs.
printf 'k0smotron:\n  enabled: false\n'                   >"$V/mgmt-k0smotron-external.yaml"
printf 'certSync:\n  secrets: null\n'                     >"$V/neg-mgmt-certsync-no-secrets.yaml"
printf 'certSync:\n  schedule: "@daily"\n'                >"$V/neg-mgmt-certsync-schedule-macro.yaml"
printf 'certSync:\n  schedule: "23 3 * * 1"\n'            >"$V/neg-mgmt-certsync-schedule-weekly.yaml"

# An entry with no destination.namespace. There is deliberately no default, so
# this must be an error rather than a Secret written where nothing reads it.
cat >"$V/neg-mgmt-certsync-no-destination.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination:
        name: ca-bundle
EOF

# No `keys` map: the whole-Secret copy that would put the fleet CA private key
# on every edge.
cat >"$V/neg-mgmt-certsync-no-keys.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
      destination: {namespace: logging, name: ca-bundle}
EOF

# The CA Secret sourced from the wrong namespace. cert-manager writes it into
# its --cluster-resource-namespace; one namespace away it exists and never
# syncs, and every run logs sync_failed rather than erroring.
# The certSync entry that delivers the edge S3 credential names its source as
# "<edge>-s3", but cert-sync substitutes <edge> and nothing else — so an edge
# whose s3SecretRef points somewhere else would have the credential synced from
# a Secret that does not exist. sync_failed every six hours, the edge never
# receives s3-edge-credentials, and its uploader sits in
# CreateContainerConfigError; none of the three symptoms names the cause.
cat >"$V/neg-mgmt-certsync-s3-name-mismatch.yaml" <<'EOF'
edges:
  - name: edge-alpha
    nodeIP: "10.0.0.2"
    s3SecretRef: some-other-name
    uploadSecretRef: seaweedfs-upload
    exposure: sni
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: xnat-ingest, name: ca-bundle, type: Opaque}
    - source:
        namespace: ais-mgmt
        name: "<edge>-s3"
        keys: {access-key: access-key, secret-key: secret-key}
      destination: {namespace: xnat-ingest, name: s3-edge-credentials, type: Opaque}
EOF

cat >"$V/neg-mgmt-certsync-ca-wrong-ns.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: ais-mgmt
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: logging, name: ca-bundle}
EOF

# Copying tls.key out of the CA Secret: every edge could then mint a
# certificate for any hostname in the fleet.
cat >"$V/neg-mgmt-certsync-tls-key.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys:
          ca.crt: ca.crt
          tls.key: tls.key
      destination: {namespace: logging, name: ca-bundle}
EOF

# mTLS on the push path with no distribution mechanism at all: cert-manager
# issues every client certificate on the management cluster and nothing carries
# any of them to a site.
printf 'certSync:\n  enabled: false\n'                    >"$V/neg-mgmt-loki-mtls-no-certsync.yaml"

# certSync is on and well-formed, but carries only the CA bundle. The push
# Ingress still demands a client certificate, so every edge fails the handshake
# — and the alerts that would report it are built from the logs that stop.
cat >"$V/neg-mgmt-loki-mtls-no-client-cert.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: logging, name: ca-bundle, type: Opaque}
EOF

# ---- S3 mTLS ordering --------------------------------------------------------
# The hazard these four guard: turning verification on before the client
# certificates are on the edges rejects every upload at the TLS handshake, and
# that rejection reaches the uploader as a generic connection error — no 403,
# no S3 error code — so it reads as a dead endpoint rather than as an auth
# problem. Each case injects one step of the rollout done out of order.

# require without issue: the Ingress demands a certificate while nothing mints
# one and the CA anchor Secret it names does not exist.
cat >"$V/neg-mgmt-s3-mtls-require-no-issue.yaml" <<'EOF'
seaweedfs:
  ingress:
    clientCerts:
      issue: false
      require: true
EOF

# Certificates issued with no distribution mechanism at all. requireAuth is
# turned off so the LOKI certSync guard — which fires on the same values and is
# rendered from an earlier file — cannot satisfy this case for the wrong reason.
cat >"$V/neg-mgmt-s3-mtls-no-certsync.yaml" <<'EOF'
seaweedfs:
  ingress:
    clientCerts:
      issue: true
certSync:
  enabled: false
observability:
  loki:
    push:
      requireAuth: false
EOF

# certSync is on and well-formed but carries no S3 client certificate: the
# identities are minted on the management cluster and never reach a site.
cat >"$V/neg-mgmt-s3-mtls-no-client-cert.yaml" <<'EOF'
seaweedfs:
  ingress:
    clientCerts:
      issue: true
observability:
  loki:
    push:
      requireAuth: false
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: xnat-ingest, name: ca-bundle, type: Opaque}
EOF

# The reverse: the certSync entry uncommented without the flag. Nothing creates
# the source Secret, so that one entry logs sync_failed every six hours while
# every other Secret in the same run syncs fine.
cat >"$V/neg-mgmt-s3-certsync-entry-no-issue.yaml" <<'EOF'
observability:
  loki:
    push:
      requireAuth: false
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: xnat-ingest, name: ca-bundle, type: Opaque}
    - source:
        namespace: ais-mgmt
        name: "<edge>-s3-client"
        keys: {tls.crt: tls.crt, tls.key: tls.key}
      destination: {namespace: xnat-ingest, name: s3-client-tls, type: kubernetes.io/tls}
EOF

# | , = are the delimiters of the spec file cert-sync.sh parses, so a name
# containing one is read as a different instruction rather than rejected.
cat >"$V/neg-mgmt-certsync-delimiter-in-name.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: ca.crt}
      destination: {namespace: logging, name: "ca-bundle,extra"}
EOF

cat >"$V/neg-mgmt-certsync-delimiter-in-key.yaml" <<'EOF'
certSync:
  secrets:
    - source:
        namespace: cert-manager
        name: ais-edge-ca-secret
        keys: {ca.crt: "ca.crt=x"}
      destination: {namespace: logging, name: ca-bundle}
EOF

# A CronJob name over 52 characters is rejected by the API server partway
# through an upgrade, because the controller appends a timestamp to derive Job
# names. "mgmt-cert-sync-" is 15, so the edge name below takes it to 57.
cat >"$V/neg-mgmt-certsync-cronjob-name-too-long.yaml" <<'EOF'
edges:
  - name: edge-with-a-name-long-enough-to-overflow-it
    s3SecretRef: edge-long-s3
    exposure: sni
EOF

# -- edge ---------------------------------------------------------------------
printf 'upload:\n  mode: both\n'                          >"$V/neg-edge-bad-mode.yaml"
printf 'upload:\n  s3:\n    endpoint: ""\n'               >"$V/neg-edge-s3-no-endpoint.yaml"
# perSiteBuckets derives <bucketPrefix>-<clusterLabel>, which is safe and is
# now the normal path — so an empty bucket alone is no longer an error. What
# must still be refused is the SHARED-bucket layout with no explicit name: a
# defaulted shared bucket is the original isolation bug, because SeaweedFS
# scopes identities per bucket with no prefix scoping, so every site sharing
# one bucket can read and delete every other site's staged imaging.
printf 'seaweedfs:\n  perSiteBuckets: false\nupload:\n  s3:\n    bucket: ""\n' >"$V/neg-edge-s3-no-bucket.yaml"
printf 'upload:\n  s3:\n    caBundleSecret: ""\n'         >"$V/neg-edge-https-no-ca.yaml"
# requireClientCert with nothing to mount. The volume renders with an empty
# secretName, which is valid YAML — so every parsing stage passes and the
# uploader sits in CreateContainerConfigError on the edge instead.
printf 'upload:\n  s3:\n    requireClientCert: true\n    clientCertSecret: ""\n' >"$V/neg-edge-s3-no-client-secret.yaml"
printf 'deid:\n  policyReviewed: false\n'                  >"$V/neg-edge-deid-not-reviewed.yaml"
# The pre-rename path. Accepting it as an alias would leave the very confusion
# the move exists to end, so it must fail and name the new key.
printf 'orthanc:\n  deid:\n    policyReviewed: true\n' >"$V/neg-edge-deid-moved-key.yaml"
# The management uploader with no settle period reads a session while the edge
# is still writing it into the bucket, uploads the fraction that has landed,
# and then skips the short resource for ever as 'already uploaded'.
printf 'xnatUpload:\n  waitPeriod: 0\n' >"$V/neg-mgmt-upload-no-wait.yaml"
printf 'orthanc:\n  deid:\n    aetMap: null\n'            >"$V/neg-edge-deid-empty-aetmap.yaml"
printf 'orthanc:\n  deid:\n    profile: null\n'           >"$V/neg-edge-deid-empty-profile.yaml"

printf 'deid:\n  engine: ingset\n' >"$V/neg-edge-deid-bad-engine.yaml"
printf 'deid:\n  engine: ingest\ningest:\n  assign:\n    tagMapping: {project: StudyID, subject: PSEUDONYM_TAG, session: PSEUDONYM_SESSION_TAG}\n  deidentify:\n    specConfigMap: ""\n' >"$V/neg-edge-deid-no-specs.yaml"
printf 'deid:\n  engine: none\n  policyReviewed: false\n' >"$V/neg-edge-deid-no-engine.yaml"
printf 'deid:\n  engine: ingest\ningest:\n  assign:\n    tagMapping: {project: StudyID, subject: PSEUDONYM_TAG, session: PSEUDONYM_SESSION_TAG}\n  deidentify:\n    specConfigMap: specs\n    specFiles: {}\n' >"$V/neg-edge-deid-no-specfiles.yaml"
printf 'orthanc:\n  deid:\n    existingSaltSecret: ""\n'  >"$V/neg-edge-deid-no-salt.yaml"

# The migration guards, which are the upgrade path for every existing site and
# execute exactly once each, in anger. Nothing had ever run them.
printf 'orthanc:\n  deid:\n    enabled: true\n'      >"$V/neg-edge-deid-legacy-orthanc-key.yaml"
printf 'ingest:\n  deidentify:\n    enabled: true\n' >"$V/neg-edge-deid-legacy-ingest-key.yaml"

# onDeidentified is satisfied by the deidentify stage unlinking its own input,
# so it is meaningless when that stage does not render.
printf 'deid:\n  engine: orthanc\ndataPolicy:\n  derived:\n    assigned:\n      reclaim: onDeidentified\n' >"$V/neg-edge-reclaim-ondeid-no-stage.yaml"
printf 'dataPolicy:\n  derived:\n    assigned:\n      reclaim: onAssigned\n' >"$V/neg-edge-reclaim-onassigned-on-assigned.yaml"
printf 'dataPolicy:\n  derived:\n    grouped:\n      reclaim: onUploaded\n      location: /data/custom\n' >"$V/neg-edge-reclaim-onuploaded-on-grouped.yaml"
printf 'dataPolicy:\n  derived:\n    assigned:\n      location: /data/assigned-x\n' >"$V/neg-edge-reclaim-onuploaded-moved-assigned.yaml"

# onUploaded needs a marker that only the s3-uploader writes, and upload.mode
# =direct renders no s3-uploader. The condition could never come true, so the
# tree would be kept for ever while the policy read as if it were being cleaned.
printf 'upload:\n  mode: direct\ndataPolicy:\n  derived:\n    deidentified:\n      reclaim: onUploaded\n' >"$V/neg-edge-reclaim-deid-onuploaded.yaml"

# A recovery window on a tree the stage deletes at handoff can never elapse.
# Also the only live exercise of the durationSeconds/int64 path in that guard.
cat >"$V/neg-edge-reclaim-ondeid-minage.yaml" <<'EOF'
deid:
  engine: ingest
dataPolicy:
  derived:
    assigned:
      reclaim: onDeidentified
      minAge: 1d
ingest:
  assign:
    tagMapping: {project: StudyID, subject: PSEUDONYM_TAG, session: PSEUDONYM_SESSION_TAG}
  deidentify:
    specs:
      "__default__/medimage/dicom-series": |
        FORMAT dicom
EOF

# A COMPLETE ais-deid site that reclaims its terminal tree. Under direct upload
# that tree is /data/deidentified and nothing used to be able to retire it: the
# chart failed the render because onUploaded had no writer. The stagedReclaimer
# CronJob is that writer's replacement, so this combination must now RENDER.
# Paired with the neg-edge-reclaim-deid-onuploaded case, which keeps the same
# declaration failing under Orthanc-deid, where the tree really is unwatched.
cat >"$V/edge-deid-ingest.yaml" <<'EOF'
deid:
  engine: ingest
dataPolicy:
  derived:
    assigned:
      reclaim: onDeidentified
    deidentified:
      reclaim: onUploaded
ingest:
  assign:
    tagMapping: {project: StudyID, subject: PSEUDONYM_TAG, session: PSEUDONYM_SESSION_TAG}
  deidentify:
    specs:
      "__default__/medimage/dicom-series": |
        FORMAT dicom
EOF

cat >"$V/neg-edge-deid-no-facilitybackup.yaml" <<'EOF'
storage:
  facilityBackup:
    enabled: false
EOF

# The two Orthanc secrets under the DEFAULT engine. Both guards used to be gated
# on deid.engine=orthanc while the values they protect are mounted on conditions
# with no engine test, so neither was reachable from what a new site installs.
cat >"$V/neg-edge-ingest-no-authsecret.yaml" <<'EOF'
orthanc:
  auth:
    enabled: true
    existingSecret: ""
EOF

cat >"$V/neg-edge-ingest-no-salt.yaml" <<'EOF'
orthanc:
  deid:
    existingSaltSecret: ""
EOF

# The routing tags only the Lua hook writes, with the Lua hook not selected:
# every session lands in __invalid__ still carrying its PHI. The old
# orphaned-toProcessLabel case is gone because the chart now derives that label
# from the engine, so it cannot be left dangling.
cat >"$V/neg-edge-deid-lua-tags.yaml" <<'EOF'
deid:
  engine: ingest
dataPolicy:
  derived:
    assigned:
      reclaim: onDeidentified
ingest:
  # EXPLICIT NOW, and that is the point of this case. The chart default used to
  # BE the ClinicalTrial* triple, so an ingest-engine fixture reached this guard
  # by doing nothing. The default is now the modality tags, so a site only trips
  # this guard by leaving the old values behind after switching engines, which is
  # exactly the mistake it exists to catch. The fixture has to state them.
  assign:
    tagMapping:
      project: ClinicalTrialProtocolID
      subject: ClinicalTrialSubjectID
      session: ClinicalTrialTimePointID
  deidentify:
    specs:
      "__default__/medimage/dicom-series": |
        FORMAT dicom
EOF

# Reclaiming the operator's only copy.
cat >"$V/neg-mgmt-podlogfiles-retain.yaml" <<'EOF'
dataPolicy:
  telemetry:
    podLogFiles: {retain: 14d}
EOF

cat >"$V/neg-mgmt-quarantine-retain.yaml" <<'EOF'
dataPolicy:
  originals:
    quarantine:
      retain: 90d
EOF

cat >"$V/neg-mgmt-telemetry-retain.yaml" <<'EOF'
dataPolicy:
  telemetry:
    prometheus: {retain: 90d}
EOF

cat >"$V/neg-edge-grouped-minage.yaml" <<'EOF'
dataPolicy:
  derived:
    grouped:
      minAge: 3600
EOF

# An unparseable duration must FAIL the render, never default to 0. Zero would
# read as "expire immediately", which on an originals stage means discarding the
# archive of record because someone typed "7 days" instead of "7d".
cat >"$V/neg-edge-bad-duration.yaml" <<'EOF'
dataPolicy:
  derived:
    assigned:
      minAge: "7 days"
EOF

# Same guard on the management side. Both charts read the SAME dataPolicy block
# from the site file, so a duration the two disagree about would mean the edge
# and the reclaimer enforcing different windows from one line of config.
cat >"$V/neg-mgmt-bad-duration.yaml" <<'EOF'
dataPolicy:
  originals:
    quarantine:
      alertAfter: "one day"
EOF

# More than 10 digits is refused, not parsed. A long enough number overflows,
# and int64 turned an overflow into 0. 11 digits is the first length refused.
printf 'dataPolicy:\n  derived:\n    assigned:\n      minAge: "10000000000d"\n' >"$V/neg-edge-duration-11-digits.yaml"
printf 'dataPolicy:\n  stageAgeAlertAfter: "10000000000s"\n'                  >"$V/neg-mgmt-duration-11-digits.yaml"

cat >"$V/neg-edge-filedrop-reclaim.yaml" <<'EOF'
dataPolicy:
  enabled: true
  originals:
    fileDrop:
      reclaim: onIngested
ingest:
  fileDrop:
    enabled: true
EOF

printf 'hostAliases:\n  mgmtNodeIP: ""\n'                 >"$V/neg-edge-hostaliases-no-ip.yaml"
printf 'clusterLabel: ""\n'                               >"$V/neg-edge-no-clusterlabel.yaml"

# -- cloud ingress shape ------------------------------------------------------
# The on-prem default left in place on cloud: binds the host's :443, never asks
# for a load balancer, and the controller still reports 1/1 Running.
cat >"$V/neg-mgmt-cloud-hostnetwork.yaml" <<'EOF'
topology: cloud
ingress-nginx:
  controller:
    hostNetwork: true
EOF

# Reachable from nowhere outside the cluster.
cat >"$V/neg-mgmt-cloud-clusterip.yaml" <<'EOF'
topology: cloud
ingress-nginx:
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst
    service:
      type: ClusterIP
EOF

# ClusterFirstWithHostNet without hostNetwork: the pod gets the HOST's
# resolv.conf and loses its in-cluster upstreams.
# nodePort is the CHART DEFAULT, so an edge that omits `exposure` lands on the
# mode that reaches nothing on cloud. This fixture states it explicitly.
cat >"$V/neg-mgmt-cloud-nodeport.yaml" <<'EOF'
topology: cloud
ingress-nginx:
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst
    service:
      type: LoadBalancer
edges:
  - name: edge-alpha
    nodeIP: 198.51.100.21
    s3SecretRef: edge-alpha-s3
    exposure: nodePort
    apiNodePort: 30443
    konnectivityNodePort: 30132
EOF

cat >"$V/neg-mgmt-cloud-dnspolicy.yaml" <<'EOF'
topology: cloud
ingress-nginx:
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirstWithHostNet
    service:
      type: LoadBalancer
EOF

# Orthanc auth on with nothing to authenticate against. The deployment mounts
# existingSecret non-optionally, so an empty name fails as a volume error
# rather than as an auth error.
# Orthanc auth ON with a populated Secret: the shape a site that turns auth on
# actually runs. Renders both consumers, so the values-consumers and render
# stages see the credential wiring rather than only the negative case.
cat >"$V/edge-auth-on.yaml" <<'EOF'
orthanc:
  auth:
    enabled: true
    existingSecret: orthanc-credentials
EOF

cat >"$V/neg-edge-auth-no-secret.yaml" <<'EOF'
orthanc:
  auth:
    enabled: true
    existingSecret: ""
EOF

# xnat-ingest's Orthanc grouping accepts ONLY hardlink_or_copy and raises
# NotImplementedError at RUN TIME for anything else, so without this guard the
# pod renders, starts and then CrashLoops with a message that never names the
# setting that caused it.
printf 'ingest:\n  orthancGroup:\n    copyMode: copy\n' >"$V/neg-edge-orthanc-copymode.yaml"

# Recipes for an engine that is not selected. deid.engine defaults to orthanc, so
# this is what a site gets by pasting specs into values.yaml and changing nothing
# else: the ConfigMap and the deidentify stage are both gated on the engine, so
# helm succeeds and the recipe is silently never mounted.
cat >"$V/neg-edge-specs-wrong-engine.yaml" <<'EOF'
ingest:
  deidentify:
    specs:
      __default__/medimage/dicom-series: |
        REMOVE PatientBirthDate
EOF


# =============================================================================
# Case tables
# =============================================================================
# Format, tab-separated:
#   positive   name <TAB> chart-dir <TAB> space-separated values basenames
#   negative   name <TAB> chart-dir <TAB> values basenames <TAB> expected text
#
# The expected text is matched against the COMBINED stdout+stderr of
# `helm template`. It is a distinctive fragment of the guard's own message —
# long enough that a different guard firing cannot satisfy it by accident.

# THE COMBINATION EVERY SHIPPED SITE ACTUALLY RUNS, which until now no fixture
# did. edge-base's profile rewrites only PatientName and the three
# ClinicalTrial* tags, so StudyID survives de-identification there and reading
# it resolves what the modality wrote. Every sites/*/values.yaml under
# deid.engine=orthanc ALSO rewrites StudyID, AccessionNumber and PatientID to
# strip identity, and that is the shape that misroutes.
#
# MEASURED on a fresh tier-1 install of sites/stream-2-ab-dev before the guard
# existed: 531 instances staged as
#   assigned/A9BB5B6D36EE.test_project-0A326BB4F373.A9BB5B6D36EE
# and the uploader then failed every pass with "Project 'A9BB5B6D36EE' does not
# exist on XNAT". Nothing in the suite rendered that combination, so nothing
# could report it.
cat >"$V/edge-deid-site-profile.yaml" <<'EOF'
orthanc:
  deid:
    profile:
      Replace:
        StudyID: "${SessionHash}"
        AccessionNumber: "${SessionHash}"
        PatientID: "${ProjectCode}-${SubjectHash}"
EOF

# The same profile with the mapping named EXPLICITLY the way every affected site
# inherited it. It has to be explicit now: the derived default is correct under
# this engine, so the mistake is no longer reachable by omission, which is the
# point of deriving it. project resolves to the SessionHash rather than failing,
# so only a render-time guard catches it.
cat >"$V/neg-edge-assign-tag-crossed.yaml" <<'EOF'
orthanc:
  deid:
    profile:
      Replace:
        StudyID: "${SessionHash}"
        AccessionNumber: "${SessionHash}"
        PatientID: "${ProjectCode}-${SubjectHash}"
ingest:
  assign:
    tagMapping:
      project: StudyID
      subject: PatientID
      session: AccessionNumber
EOF

cat >"$V/edge-stanford.yaml" <<'EOF'
deid: {engine: none, policyReviewed: true}
storage: {facilityBackup: {enabled: false}}
orthanc: {enabled: false, externalUrl: "http://orthanc.example.invalid:8042", storageDirectory: /data/db-v6}
ingest:
  stanford:
    enabled: true
    routing: {autoImportUnlabeled: true}
    rawUploads: {enabled: true}
dataPolicy:
  originals: {facilityBackup: {enabled: false}}
  derived: {orthancStorage: {location: /data/db-v6}}
EOF

cat >"$V/mgmt-stanford.yaml" <<'EOF'
xnatUpload:
  projectProvisioning: {enabled: true, ownerUsers: [brosnan, sciget]}
  tokenRefresh: {enabled: true}
  archivePrefix: uploaded
EOF

cat >"$V/neg-edge-external-url.yaml" <<'EOF'
orthanc: {externalUrl: ""}
EOF

cat >"$V/neg-edge-external-engine.yaml" <<'EOF'
deid: {engine: orthanc}
EOF

cat >"$V/neg-edge-stanford-engine.yaml" <<'EOF'
deid: {engine: ingest}
orthanc: {enabled: true}
EOF

cat >"$V/neg-edge-stanford-filedrop.yaml" <<'EOF'
ingest: {fileDrop: {enabled: true}}
EOF

cat >"$V/neg-edge-stanford-project.yaml" <<'EOF'
ingest: {stanford: {fallbackProject: "bad/project"}}
EOF

cat >"$V/neg-edge-stanford-batch.yaml" <<'EOF'
ingest: {stanford: {routing: {batchSize: 0}}}
EOF

cat >"$V/neg-edge-stanford-paths.yaml" <<'EOF'
ingest: {stanford: {rawUploads: {archiveHostPath: /local/samba/public/xnat-upload}}}
EOF

cat >"$V/neg-edge-stanford-scan.yaml" <<'EOF'
ingest: {stanford: {rawUploads: {scan: ../escape}}}
EOF

cat >"$V/neg-edge-stanford-wait.yaml" <<'EOF'
ingest: {stanford: {rawUploads: {waitPeriod: -1}}}
EOF

cat >"$V/neg-mgmt-archive-prefix.yaml" <<'EOF'
xnatUpload: {archivePrefix: staged}
EOF

cat >"$V/neg-mgmt-token-source.yaml" <<'EOF'
xnatUpload: {tokenRefresh: {sourceSecretRef: ""}}
EOF

cat >"$V/neg-mgmt-token-shared.yaml" <<'EOF'
xnatUpload: {tokenRefresh: {sourceSecretRef: xnat-credentials}}
EOF

cat >"$V/neg-mgmt-token-no-edges.yaml" <<'EOF'
edges: []
EOF

cat >"$V/neg-mgmt-project-interval.yaml" <<'EOF'
xnatUpload: {projectProvisioning: {interval: 0}}
EOF

ci_positive_cases() {
  cat <<'EOF'
edge-stanford	charts/edge	edge-base.yaml edge-stanford.yaml
mgmt-stanford	charts/mgmt	mgmt-base.yaml mgmt-stanford.yaml
mgmt-defaults	charts/mgmt	mgmt-base.yaml
mgmt-k0smotron-external	charts/mgmt	mgmt-base.yaml mgmt-k0smotron-external.yaml
mgmt-two-edges	charts/mgmt	mgmt-base.yaml mgmt-two-edges.yaml
mgmt-reporter-optout	charts/mgmt	mgmt-base.yaml mgmt-reporter-optout.yaml
mgmt-reporter-optout-all	charts/mgmt	mgmt-base.yaml mgmt-reporter-optout-all.yaml
mgmt-reporter-optout-all-never	charts/mgmt	mgmt-base.yaml mgmt-reporter-optout-all.yaml mgmt-reporter-silent-never.yaml
mgmt-reclaimer-six-hourly	charts/mgmt	mgmt-base.yaml mgmt-reclaimer-six-hourly.yaml
mgmt-reclaimer-off	charts/mgmt	mgmt-base.yaml mgmt-reclaimer-off.yaml
mgmt-sni-exposure	charts/mgmt	mgmt-base.yaml mgmt-sni-exposure.yaml
mgmt-observability-off	charts/mgmt	mgmt-base.yaml mgmt-observability-off.yaml
mgmt-datapolicy-on	charts/mgmt	mgmt-base.yaml mgmt-datapolicy-on.yaml
mgmt-duration-base10	charts/mgmt	mgmt-base.yaml mgmt-duration-base10.yaml
mgmt-no-seaweedfs	charts/mgmt	mgmt-base.yaml mgmt-no-seaweedfs.yaml
mgmt-shared-bucket	charts/mgmt	mgmt-base.yaml mgmt-shared-bucket.yaml
mgmt-letsencrypt	charts/mgmt	mgmt-base.yaml mgmt-letsencrypt.yaml
mgmt-cloud	charts/mgmt	mgmt-cloud.yaml
mgmt-slack	charts/mgmt	mgmt-base.yaml mgmt-slack.yaml
mgmt-two-edges-datapolicy	charts/mgmt	mgmt-base.yaml mgmt-two-edges.yaml mgmt-datapolicy-on.yaml
mgmt-s3-mtls	charts/mgmt	mgmt-base.yaml mgmt-s3-mtls.yaml
mgmt-s3-mtls-issue-only	charts/mgmt	mgmt-base.yaml mgmt-s3-mtls.yaml mgmt-s3-mtls-issue-only.yaml
mgmt-s3-mtls-two-edges	charts/mgmt	mgmt-base.yaml mgmt-two-edges.yaml mgmt-s3-mtls.yaml
edge-defaults	charts/edge	edge-base.yaml
edge-deid-site-profile	charts/edge	edge-base.yaml edge-deid-site-profile.yaml
edge-upload-direct	charts/edge	edge-base.yaml edge-upload-direct.yaml
edge-observability-on	charts/edge	edge-base.yaml edge-observability-on.yaml
edge-samba-on	charts/edge	edge-base.yaml edge-samba-on.yaml
edge-filedrop-on	charts/edge	edge-base.yaml edge-filedrop-on.yaml
edge-datapolicy-on	charts/edge	edge-base.yaml edge-datapolicy-on.yaml
edge-duration-base10	charts/edge	edge-base.yaml edge-duration-base10.yaml
edge-deid-off	charts/edge	edge-base.yaml edge-deid-off.yaml
edge-cloud	charts/edge	edge-base.yaml edge-cloud.yaml
edge-direct-datapolicy	charts/edge	edge-base.yaml edge-upload-direct.yaml edge-datapolicy-on.yaml
edge-direct-ingest-reclaim	charts/edge	edge-base.yaml edge-upload-direct.yaml edge-datapolicy-on.yaml edge-deid-ingest.yaml
edge-s3-ingest	charts/edge	edge-base.yaml edge-datapolicy-on.yaml edge-deid-ingest.yaml
edge-s3-mtls	charts/edge	edge-base.yaml edge-s3-mtls.yaml
edge-s3-mtls-no-cabundle	charts/edge	edge-base.yaml edge-s3-mtls-no-cabundle.yaml
edge-auth-on	charts/edge	edge-base.yaml edge-auth-on.yaml
edge-auth-on-datapolicy	charts/edge	edge-base.yaml edge-auth-on.yaml edge-datapolicy-on.yaml
edge-everything-on	charts/edge	edge-base.yaml edge-observability-on.yaml edge-samba-on.yaml edge-filedrop-on.yaml edge-datapolicy-on.yaml edge-s3-mtls.yaml
EOF
}

ci_negative_cases() {
  cat <<'EOF'
neg-edge-external-url	charts/edge	edge-base.yaml edge-stanford.yaml neg-edge-external-url.yaml	requires orthanc.externalUrl
neg-edge-external-engine	charts/edge	edge-base.yaml edge-stanford.yaml neg-edge-external-engine.yaml	external Orthanc requires
neg-edge-stanford-engine	charts/edge	edge-base.yaml edge-stanford.yaml neg-edge-stanford-engine.yaml	ingest.stanford.enabled requires
neg-edge-stanford-filedrop	charts/edge	edge-base.yaml edge-stanford.yaml neg-edge-stanford-filedrop.yaml	cannot run alongside
neg-edge-stanford-project	charts/edge	edge-base.yaml edge-stanford.yaml neg-edge-stanford-project.yaml	fallbackProject must be
neg-edge-stanford-batch	charts/edge	edge-base.yaml edge-stanford.yaml neg-edge-stanford-batch.yaml	batchSize must be positive
neg-edge-stanford-paths	charts/edge	edge-base.yaml edge-stanford.yaml neg-edge-stanford-paths.yaml	distinct absolute
neg-edge-stanford-scan	charts/edge	edge-base.yaml edge-stanford.yaml neg-edge-stanford-scan.yaml	single safe directory
neg-edge-stanford-wait	charts/edge	edge-base.yaml edge-stanford.yaml neg-edge-stanford-wait.yaml	waitPeriod cannot be negative
neg-mgmt-archive-prefix	charts/mgmt	mgmt-base.yaml mgmt-stanford.yaml neg-mgmt-archive-prefix.yaml	separate safe top-level
neg-mgmt-token-source	charts/mgmt	mgmt-base.yaml mgmt-stanford.yaml neg-mgmt-token-source.yaml	sourceSecretRef must name
neg-mgmt-token-shared	charts/mgmt	mgmt-base.yaml mgmt-stanford.yaml neg-mgmt-token-shared.yaml	source and target Secrets must differ
neg-mgmt-token-no-edges	charts/mgmt	mgmt-base.yaml mgmt-stanford.yaml neg-mgmt-token-no-edges.yaml	token refresh requires edges
neg-mgmt-project-interval	charts/mgmt	mgmt-base.yaml mgmt-stanford.yaml neg-mgmt-project-interval.yaml	provisioning interval must be positive
neg-edge-assign-tag-crossed	charts/edge	edge-base.yaml neg-edge-assign-tag-crossed.yaml	crosses the de-identification
neg-mgmt-no-domain	charts/mgmt	mgmt-base.yaml neg-mgmt-no-domain.yaml	domain.internal must be set
neg-mgmt-no-nodeip	charts/mgmt	mgmt-base.yaml neg-mgmt-no-nodeip.yaml	domain.mgmtNodeIP must be set
neg-mgmt-duplicate-edges	charts/mgmt	mgmt-base.yaml neg-mgmt-duplicate-edges.yaml	duplicate edge name
neg-mgmt-edge-no-name	charts/mgmt	mgmt-base.yaml neg-mgmt-edge-no-name.yaml	needs a name
neg-mgmt-edge-no-s3secret	charts/mgmt	mgmt-base.yaml neg-mgmt-edge-no-s3secret.yaml	has no s3SecretRef
neg-mgmt-edge-name-not-label	charts/mgmt	mgmt-base.yaml neg-mgmt-edge-name-not-label.yaml	is not a DNS-1123 label
neg-mgmt-edge-no-nodeport	charts/mgmt	mgmt-base.yaml neg-mgmt-edge-no-nodeport.yaml	has no apiNodePort
neg-mgmt-nodeport-out-of-range	charts/mgmt	mgmt-base.yaml neg-mgmt-nodeport-out-of-range.yaml	outside the cluster's NodePort range
neg-mgmt-nodeport-collision	charts/mgmt	mgmt-base.yaml neg-mgmt-nodeport-collision.yaml	is requested by both
neg-mgmt-bad-exposure	charts/mgmt	mgmt-base.yaml neg-mgmt-bad-exposure.yaml	has exposure
neg-mgmt-sni-with-nodeport	charts/mgmt	mgmt-base.yaml neg-mgmt-sni-with-nodeport.yaml	is exposure: sni but also sets
neg-mgmt-duplicate-hostname	charts/mgmt	mgmt-base.yaml neg-mgmt-duplicate-hostname.yaml	is claimed by both
neg-mgmt-fleetwide-hostnames	charts/mgmt	mgmt-base.yaml neg-mgmt-fleetwide-hostnames.yaml	no longer read
neg-mgmt-vector-loki-wrong-ns	charts/mgmt	mgmt-base.yaml neg-mgmt-vector-loki-wrong-ns.yaml	but this release installs Loki into
neg-mgmt-vector-loki-wrong-svc	charts/mgmt	mgmt-base.yaml neg-mgmt-vector-loki-wrong-svc.yaml	but this release's Loki Service is
neg-mgmt-loki-s3-no-seaweedfs	charts/mgmt	mgmt-base.yaml neg-mgmt-loki-s3-no-seaweedfs.yaml	requires seaweedfs.enabled=true
neg-mgmt-upload-loop-zero	charts/mgmt	mgmt-base.yaml neg-mgmt-upload-loop-zero.yaml	xnatUpload.loop must be a positive number of seconds
neg-mgmt-reporter-silent-forever	charts/mgmt	mgmt-base.yaml neg-mgmt-reporter-silent-forever.yaml	dataPolicy.reporterSilentAfter must be a finite duration of at least 1m
neg-mgmt-reporter-silent-never	charts/mgmt	mgmt-base.yaml neg-mgmt-reporter-silent-never.yaml	dataPolicy.reporterSilentAfter must be a finite duration of at least 1m
neg-mgmt-reporter-silent-empty	charts/mgmt	mgmt-base.yaml neg-mgmt-reporter-silent-empty.yaml	dataPolicy.reporterSilentAfter must be a finite duration of at least 1m
neg-mgmt-reporter-silent-0	charts/mgmt	mgmt-base.yaml neg-mgmt-reporter-silent-0.yaml	dataPolicy.reporterSilentAfter must be a finite duration of at least 1m
neg-mgmt-reporter-silent-30s	charts/mgmt	mgmt-base.yaml neg-mgmt-reporter-silent-30s.yaml	dataPolicy.reporterSilentAfter must be a finite duration of at least 1m
neg-mgmt-reclaimer-alert-after-forever	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-alert-after-forever.yaml	s3Staged.alertAfter must be longer than
neg-mgmt-reclaimer-alert-after-never	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-alert-after-never.yaml	s3Staged.alertAfter must be longer than
neg-mgmt-reclaimer-alert-after-empty	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-alert-after-empty.yaml	s3Staged.alertAfter must be longer than
neg-mgmt-reclaimer-alert-after-0	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-alert-after-0.yaml	s3Staged.alertAfter must be longer than
neg-mgmt-reclaimer-alert-after-30m	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-alert-after-30m.yaml	s3Staged.alertAfter must be longer than
neg-mgmt-reclaimer-alert-after-1h	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-alert-after-1h.yaml	must be longer than 10200s
neg-mgmt-reclaimer-six-hourly-3h	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-six-hourly-3h.yaml	must be longer than 46200s
neg-mgmt-reclaimer-every-30m-1h	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-every-30m-1h.yaml	must be longer than 6600s
neg-mgmt-no-emailto	charts/mgmt	mgmt-base.yaml neg-mgmt-no-emailto.yaml	emailTo is empty
neg-mgmt-no-smtphost	charts/mgmt	mgmt-base.yaml neg-mgmt-no-smtphost.yaml	smtpHost is empty
neg-mgmt-no-xnatsecret	charts/mgmt	mgmt-base.yaml neg-mgmt-no-xnatsecret.yaml	xnatSecretRef must name a Secret
neg-mgmt-k0smotron-emptydir	charts/mgmt	mgmt-base.yaml neg-mgmt-k0smotron-emptydir.yaml	persistence.type=emptyDir
neg-mgmt-le-no-email	charts/mgmt	mgmt-base.yaml neg-mgmt-le-no-email.yaml	requires certManager.acme.email
neg-mgmt-le-no-dns01	charts/mgmt	mgmt-base.yaml neg-mgmt-le-no-dns01.yaml	DNS-01 solver
neg-mgmt-le-staging-prod-url	charts/mgmt	mgmt-base.yaml neg-mgmt-le-staging-prod-url.yaml	still points at the PRODUCTION directory
neg-mgmt-ca-commonname	charts/mgmt	mgmt-base.yaml neg-mgmt-ca-commonname.yaml	certManager.ca.commonName
neg-mgmt-ca-bad-mode	charts/mgmt	mgmt-base.yaml neg-mgmt-ca-bad-mode.yaml	certManager.ca.mode must be
neg-mgmt-ca-intermediate-no-secret	charts/mgmt	mgmt-base.yaml neg-mgmt-ca-intermediate-no-secret.yaml	intermediate.secretRef is empty
neg-mgmt-no-cm-namespace	charts/mgmt	mgmt-base.yaml neg-mgmt-no-cm-namespace.yaml	clusterResourceNamespace is empty
neg-mgmt-no-sslpassthrough	charts/mgmt	mgmt-base.yaml neg-mgmt-no-sslpassthrough.yaml	sslPassthrough=false
neg-mgmt-reclaimer-no-uploader	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-no-uploader.yaml	xnatUpload.enabled=false
neg-mgmt-reclaimer-no-seaweedfs	charts/mgmt	mgmt-base.yaml neg-mgmt-reclaimer-no-seaweedfs.yaml	seaweedfs.enabled=false
neg-mgmt-am-configsecret	charts/mgmt	mgmt-base.yaml neg-mgmt-am-configsecret.yaml	configSecret must be
neg-mgmt-am-smtp-not-mounted	charts/mgmt	mgmt-base.yaml neg-mgmt-am-smtp-not-mounted.yaml	alertmanagerSpec.secrets must include
neg-mgmt-grafana-secret-mismatch	charts/mgmt	mgmt-base.yaml neg-mgmt-grafana-secret-mismatch.yaml	generated random password
neg-mgmt-loki-ruler-not-mounted	charts/mgmt	mgmt-base.yaml neg-mgmt-loki-ruler-not-mounted.yaml	extraVolumes must mount
neg-mgmt-prom-release-label	charts/mgmt	mgmt-base.yaml neg-mgmt-prom-release-label.yaml	would load none
neg-mgmt-certsync-no-secrets	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-no-secrets.yaml	certSync.secrets is empty
neg-mgmt-certsync-schedule-macro	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-schedule-macro.yaml	must be a 5-field cron expression
neg-mgmt-certsync-schedule-weekly	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-schedule-weekly.yaml	runs less often than daily
neg-mgmt-certsync-no-destination	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-no-destination.yaml	needs source.name, destination.namespace
neg-mgmt-certsync-no-keys	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-no-keys.yaml	has no `keys` map
neg-mgmt-certsync-s3-name-mismatch	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-s3-name-mismatch.yaml	but that edge's s3SecretRef is
neg-mgmt-certsync-ca-wrong-ns	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-ca-wrong-ns.yaml	but cert-manager writes it into
neg-mgmt-certsync-tls-key	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-tls-key.yaml	copies key tls.key out of
neg-mgmt-certsync-delimiter-in-name	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-delimiter-in-name.yaml	contains one of | , =
neg-mgmt-certsync-delimiter-in-key	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-delimiter-in-key.yaml	key mapping ca.crt=ca.crt=x
neg-mgmt-certsync-cronjob-name-too-long	charts/mgmt	mgmt-base.yaml neg-mgmt-certsync-cronjob-name-too-long.yaml	the API server rejects CronJob names over 52
neg-mgmt-loki-mtls-no-certsync	charts/mgmt	mgmt-base.yaml neg-mgmt-loki-mtls-no-certsync.yaml	but certSync.enabled=false
neg-mgmt-loki-mtls-no-client-cert	charts/mgmt	mgmt-base.yaml neg-mgmt-loki-mtls-no-client-cert.yaml	no certSync.secrets entry copies
neg-mgmt-s3-mtls-require-no-issue	charts/mgmt	mgmt-base.yaml neg-mgmt-s3-mtls-require-no-issue.yaml	clientCerts.require=true with clientCerts.issue=false
neg-mgmt-s3-mtls-no-certsync	charts/mgmt	mgmt-base.yaml neg-mgmt-s3-mtls-no-certsync.yaml	mints one S3 client certificate per edge, but certSync.enabled=false
neg-mgmt-s3-mtls-no-client-cert	charts/mgmt	mgmt-base.yaml neg-mgmt-s3-mtls-no-client-cert.yaml	but seaweedfs.ingress.clientCerts.issue mints that certificate
neg-mgmt-s3-certsync-entry-no-issue	charts/mgmt	mgmt-base.yaml neg-mgmt-s3-certsync-entry-no-issue.yaml	but seaweedfs.ingress.clientCerts.issue=false
neg-edge-bad-mode	charts/edge	edge-base.yaml neg-edge-bad-mode.yaml	upload.mode must be
neg-edge-s3-no-endpoint	charts/edge	edge-base.yaml neg-edge-s3-no-endpoint.yaml	needs an S3 endpoint, and none could be derived
neg-edge-s3-no-bucket	charts/edge	edge-base.yaml neg-edge-s3-no-bucket.yaml	no staging bucket could be derived
neg-edge-https-no-ca	charts/edge	edge-base.yaml neg-edge-https-no-ca.yaml	every upload would fail the TLS handshake
neg-edge-s3-no-client-secret	charts/edge	edge-base.yaml neg-edge-s3-no-client-secret.yaml	upload.s3.clientCertSecret is empty
neg-edge-deid-not-reviewed	charts/edge	edge-base.yaml neg-edge-deid-not-reviewed.yaml	requires deid.policyReviewed=true
neg-edge-deid-moved-key	charts/edge	edge-base.yaml neg-edge-deid-moved-key.yaml	has MOVED to deid.policyReviewed
neg-mgmt-upload-no-wait	charts/mgmt	mgmt-base.yaml neg-mgmt-upload-no-wait.yaml	xnatUpload.waitPeriod is 0
neg-edge-deid-empty-aetmap	charts/edge	edge-base.yaml neg-edge-deid-empty-aetmap.yaml	aetMap is empty
neg-edge-deid-bad-engine	charts/edge	edge-base.yaml neg-edge-deid-bad-engine.yaml	must be one of orthanc, ingest or none
neg-edge-deid-no-specs	charts/edge	edge-base.yaml neg-edge-deid-no-specs.yaml	no recipes are configured
neg-edge-deid-no-engine	charts/edge	edge-base.yaml neg-edge-deid-no-engine.yaml	deid.engine=none, so nothing in this pipeline de-identifies
neg-edge-deid-no-specfiles	charts/edge	edge-base.yaml neg-edge-deid-no-specfiles.yaml	specFiles is empty
neg-edge-deid-empty-profile	charts/edge	edge-base.yaml neg-edge-deid-empty-profile.yaml	profile is empty
neg-edge-deid-no-salt	charts/edge	edge-base.yaml neg-edge-deid-no-salt.yaml	existingSaltSecret is empty
neg-edge-deid-legacy-orthanc-key	charts/edge	edge-base.yaml neg-edge-deid-legacy-orthanc-key.yaml	has been replaced by the single key
neg-edge-deid-legacy-ingest-key	charts/edge	edge-base.yaml neg-edge-deid-legacy-ingest-key.yaml	has been replaced by the single key
neg-edge-reclaim-ondeid-no-stage	charts/edge	edge-base.yaml neg-edge-reclaim-ondeid-no-stage.yaml	is not ingest
neg-edge-reclaim-onassigned-on-assigned	charts/edge	edge-base.yaml neg-edge-reclaim-onassigned-on-assigned.yaml	is not a word this stage accepts
neg-edge-reclaim-onuploaded-on-grouped	charts/edge	edge-base.yaml neg-edge-reclaim-onuploaded-on-grouped.yaml	is not a word this stage accepts
neg-edge-reclaim-onuploaded-moved-assigned	charts/edge	edge-base.yaml neg-edge-reclaim-onuploaded-moved-assigned.yaml	while the uploader reads
neg-edge-reclaim-ondeid-minage	charts/edge	edge-base.yaml neg-edge-reclaim-ondeid-minage.yaml	is set alongside reclaim=onDeidentified
neg-edge-reclaim-deid-onuploaded	charts/edge	edge-base.yaml neg-edge-reclaim-deid-onuploaded.yaml	with upload.mode=direct
neg-edge-deid-no-facilitybackup	charts/edge	edge-base.yaml neg-edge-deid-no-facilitybackup.yaml	dropped at the front door
neg-edge-ingest-no-authsecret	charts/edge	edge-base.yaml neg-edge-ingest-no-authsecret.yaml	orthanc.auth.existingSecret is empty
neg-edge-ingest-no-salt	charts/edge	edge-base.yaml neg-edge-ingest-no-salt.yaml	existingSaltSecret is empty
neg-edge-deid-lua-tags	charts/edge	edge-base.yaml neg-edge-deid-lua-tags.yaml	still reads project=
neg-edge-filedrop-reclaim	charts/edge	edge-base.yaml neg-edge-filedrop-reclaim.yaml	that directory is the only copy
neg-edge-hostaliases-no-ip	charts/edge	edge-base.yaml neg-edge-hostaliases-no-ip.yaml	hostAliases.mgmtNodeIP is empty
neg-edge-no-clusterlabel	charts/edge	edge-base.yaml neg-edge-no-clusterlabel.yaml	clusterLabel must be set
neg-mgmt-cloud-hostnetwork	charts/mgmt	mgmt-base.yaml neg-mgmt-cloud-hostnetwork.yaml	hostNetwork=true
neg-mgmt-cloud-clusterip	charts/mgmt	mgmt-base.yaml neg-mgmt-cloud-clusterip.yaml	service.type=ClusterIP
neg-mgmt-cloud-dnspolicy	charts/mgmt	mgmt-base.yaml neg-mgmt-cloud-dnspolicy.yaml	dnsPolicy=ClusterFirstWithHostNet without hostNetwork
neg-mgmt-cloud-nodeport	charts/mgmt	mgmt-base.yaml neg-mgmt-cloud-nodeport.yaml	exposure=nodePort with topology=cloud
neg-edge-auth-no-secret	charts/edge	edge-base.yaml neg-edge-auth-no-secret.yaml	existingSecret is empty
neg-edge-bad-duration	charts/edge	edge-base.yaml neg-edge-bad-duration.yaml	is not a duration I can parse
neg-mgmt-bad-duration	charts/mgmt	mgmt-base.yaml neg-mgmt-bad-duration.yaml	is not a duration I can parse
neg-edge-duration-11-digits	charts/edge	edge-base.yaml neg-edge-duration-11-digits.yaml	has more than 10 digits
neg-mgmt-duration-11-digits	charts/mgmt	mgmt-base.yaml neg-mgmt-duration-11-digits.yaml	has more than 10 digits
neg-edge-grouped-minage	charts/edge	edge-base.yaml neg-edge-grouped-minage.yaml	was removed and setting it does nothing
neg-mgmt-telemetry-retain	charts/mgmt	mgmt-base.yaml neg-mgmt-telemetry-retain.yaml	were removed: Helm cannot template a subchart
neg-mgmt-podlogfiles-retain	charts/mgmt	mgmt-base.yaml neg-mgmt-podlogfiles-retain.yaml	has no time-based retention
neg-mgmt-quarantine-retain	charts/mgmt	mgmt-base.yaml neg-mgmt-quarantine-retain.yaml	the only supported value is
neg-edge-orthanc-copymode	charts/edge	edge-base.yaml neg-edge-orthanc-copymode.yaml	is not supported
neg-edge-specs-wrong-engine	charts/edge	edge-base.yaml neg-edge-specs-wrong-engine.yaml	is set, but deid.engine=
EOF
}

# Run directly: write the files and list what was defined.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "values written to $V"
  echo
  echo "positive cases:"; ci_positive_cases | cut -f1 | sed 's/^/  /'
  echo "negative cases:"; ci_negative_cases | cut -f1 | sed 's/^/  /'
fi
