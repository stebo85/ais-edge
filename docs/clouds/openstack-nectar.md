# OpenStack / Nectar Research Cloud install

This is the path that has been **end-to-end tested**. The mgmt cluster is
a single Nectar VM running k0s; the cloud LB is Octavia (amphora driver).
DNS is a `nip.io` wildcard for dev, switchable to your own zone for prod.

## Prerequisites

1. A Nectar project with available quota for:
   - 1 VM for the mgmt cluster (4 vCPU / 8 GB / 40 GB is plenty)
   - 1 VM per edge site (2 vCPU / 4 GB / 40 GB)
   - 1 LBaaS unit (Octavia amphora)
   - 1 floating IP (only if you want a fixed public IP — see "Topology quirks" below)
2. An **application credential** from your dashboard
   (Identity → Application Credentials → Create → Download openrc.sh).
3. Python, `openstack` CLI, `kubectl`, `helm` available on the mgmt VM. The
   install scripts handle the rest.

## Minimum config

Edit `config/management.env`:

```bash
export INSTALL_TOPOLOGY="cloud"
export CLOUD_PROVIDER="openstack"
export CLOUD_CREDENTIALS_FILE="/path/to/openrc.sh"
export LB_SUBNET_ID="<subnet UUID where the mgmt VM has a port>"
export LB_AVAILABILITY_ZONE="<AZ matching the mgmt VM's AZ>"
export INTERNAL_DOMAIN="dev-nectar-test.<lb-ip-with-dashes>.nip.io"
export CERT_ISSUER="ais-edge-ca-issuer"   # nip.io can't use Let's Encrypt
```

Run `./install.sh -y` (with your shell having sourced the openrc OR the
file path set above).

## Discovering the right values

```bash
source /path/to/openrc.sh

# Mgmt VM's AZ
openstack server show <mgmt-vm-name> -f value -c OS-EXT-AZ:availability_zone

# Subnet where the mgmt VM lives
openstack server show <mgmt-vm-name> -f value -c addresses
openstack network show <network-name> -f value -c subnets

# Available LBaaS AZs (must include the AZ you set above)
openstack loadbalancer availabilityzone list
```

## Nectar-specific topology quirks

The Nectar tenant networking has two oddities that bit us during commissioning
and the codebase now handles them:

### 1. Octavia defaults to `melbourne-qh2` for new LBs

If you don't set `LB_AVAILABILITY_ZONE`, Octavia spawns the amphora in
Melbourne regardless of where your VMs are. The LB then hangs in
`PENDING_CREATE` forever because the amphora can't reach the backend
ports (cross-region). **Always set `LB_AVAILABILITY_ZONE` to match your
mgmt VM's AZ.**

### 2. The qld network is BOTH external and where your VMs live

On most OpenStack deployments you'd allocate a floating IP and tell OCCM
to associate it: `LB_PUBLIC_IP=203.101.x.y`. On Nectar QLD that doesn't
work — Neutron rejects FIP association with
`ExternalGatewayForFloatingIPNotFound` because there's no router between
qld and itself.

The fix is to **leave `LB_PUBLIC_IP` empty** and let Octavia auto-assign
a VIP from the qld pool. That VIP is already a public IP. After install,
discover it with:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # may show <pending>
openstack loadbalancer list -c name -c vip_address          # authoritative
```

Then update `INTERNAL_DOMAIN` (or DNS) to point at the discovered VIP.
This is captured in the codebase — `LB_PUBLIC_IP=""` is supported and
documented.

### 3. The project's default security group blocks NodePort

By default Nectar's `default` SG only allows `:22` and intra-SG traffic.
The LB's amphora is in a separate Octavia-managed SG, so it can't reach
the K8s NodePort (`30000-32767`) on the mgmt VM. You must open them:

```bash
source /path/to/openrc.sh
openstack security group rule create --ingress --protocol tcp \
    --dst-port 443        --remote-ip 0.0.0.0/0 default
openstack security group rule create --ingress --protocol tcp \
    --dst-port 80         --remote-ip 0.0.0.0/0 default
openstack security group rule create --ingress --protocol tcp \
    --dst-port 30000:32767 --remote-ip 0.0.0.0/0 default
```

Or via the dashboard: Network → Security Groups → default → Add Rule.

### 4. OCCM can't auto-detect the LB subnet on self-managed k0s

The upstream OCCM normally reads each node's `providerID` to figure out
which subnet to put the LB on. k0s nodes have an empty `providerID`
(we don't run kubelet with `--cloud-provider=external`). The codebase
writes an explicit `subnet-id` into `cloud.conf` (step 01b reads
`LB_SUBNET_ID` from config) — required, no auto-detection.

### 5. Stuck LBs can't be force-deleted by app-credential users

If the LB ever ends up in `PENDING_CREATE` due to an AZ mismatch or
config problem, the API rejects deletes with HTTP 409 until Octavia's
internal timeout. App-credential users have no admin scope to force
deletion. Workaround: change `OCCM_CLUSTER_NAME` env var (passed to
01b) to a new value — OCCM will create a fresh LB with a different name
and ignore the orphaned one until Nectar admin cleans it up or the
amphora-build timeout fires.

## What the install does

| Step | What | Cloud-specific notes |
|---|---|---|
| 01  | Installs k0s on the mgmt VM | Same as onprem |
| 01b | Installs `cloud-provider-openstack` (OCCM) | Reads `LB_SUBNET_ID` + `LB_AVAILABILITY_ZONE` from env; writes them into `cloud.conf` |
| 02  | cert-manager + k0smotron | Same |
| 02b | Bootstrap self-signed CA (`ais-edge-ca`) | Cert SANs are DNS-only in cloud mode (no IP SANs) |
| 02c | nginx-ingress as `Service type=LoadBalancer` | OCCM provisions an Octavia LB. `helm --wait` is intentionally skipped because OCCM can't mark the Service ready (FIP retry loop) — kubectl wait on the controller pods is the real check |
| 03  | SeaweedFS Deployment + Service (`ClusterIP`) + Ingress | Ingress hostname comes from `SEAWEEDFS_HOSTNAME` |
| 04  | XNAT upload pod | Same |
| 02d | Observability (Loki + Prom + Grafana + Vector + Alertmanager) | Ingresses for Grafana + Loki hostnames |
| 05  | Per edge: `K0smotronControlPlane` resource | k0s API exposed through the same SNI ingress |
| 06  | Per edge: install k0s worker, join through the LB | Cloud mode skips the `/etc/hosts` + CoreDNS-patch the onprem path does |
| 07  | Per edge: xnat-ingest sort + s3-uploader pods | `hostAliases:` block stripped in cloud mode |
| 07b | Per edge: Vector log shipper | Push endpoint is the public Loki hostname |
| 07c | Per edge: Orthanc + label Lua hook | Same |

## Verification checklist

After install, from a host that's NOT the mgmt VM (e.g. the edge VM):

```bash
# DNS resolves to the LB VIP
getent hosts seaweedfs.dev-nectar-test.<lb-ip-dashes>.nip.io
# Should be 203.101.x.y (the LB VIP)

# TLS handshake completes + 403 from SeaweedFS S3 (which requires auth)
curl -kv https://seaweedfs.dev-nectar-test.<lb-ip-dashes>.nip.io/
# Expect HTTP 403

# Loki readiness
curl -kv https://loki.dev-nectar-test.<lb-ip-dashes>.nip.io/ready
# Expect HTTP 200

# Drop test: POST a DICOM to Orthanc REST, watch the upload_completed event
# (full procedure in the parent docs/cloud-deployment.md)
```

## Dev → Prod swap

The dev test uses nip.io because Let's Encrypt rejects nip.io (anti-abuse).
For production with your own domain:

```bash
export INTERNAL_DOMAIN="aisedge.example.com"   # YOUR zone
export CERT_ISSUER="letsencrypt-prod"          # real LE certs
export DNS_PROVIDER="cloudflare"               # for the DNS-01 solver
# Plus a cloudflare-api-token Secret in the cert-manager namespace
```

Re-run `./install.sh -y`. Everything else is unchanged.

## Tested cluster topology (commissioning, 2026-05-25)

- Mgmt: 203.101.224.240 (`stream-2_AB_dev`, QRIScloud AZ)
- LB:   203.101.228.227 (Octavia amphora, QRIScloud AZ, qld subnet)
- Edge: 203.101.230.171 (`k0s-edge-worker-dev`, QRIScloud AZ)
- DNS:  `*.dev-nectar-test.203-101-228-227.nip.io`
- Pipeline: DICOM REST POST → Orthanc → sort REST-pull → s3-uploader → SeaweedFS S3 → `upload_completed` event with `bytes=13427, dicoms=1, files=3`
