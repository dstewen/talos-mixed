# Rebuild — Full Cluster Reinstallation

When to use this: hardware failure, cluster corruption, security incident, or intentional migration to new hardware.

> **Warning:** This procedure destroys all cluster state. Ensure backups are available before proceeding. See `disaster-recovery.md` first.

---

## Prerequisites

- All backup sources are accessible (MinIO, NFS, Backblaze B2)
- Replacement hardware is ready with matching specs (or upgraded)
- `cluster.toml`, `deploy.key`, and SOPS age key are preserved from backup
- DNS records can be updated (VIPs may change if network layout changes)

---

## Option A: Full Hardware Replacement (Keep Same IPs)

If replacing failed nodes with identical hardware, you can reuse the same IPs and MAC addresses.

### Step 1: Prepare Replacement Nodes

1. Flash Talos on each replacement node (see `bootstrap.md` §2)
2. Record MAC addresses and disk serials in `talos/topf.yaml`
3. If MACs differ, update `talos/topf.yaml` with the new MACs

### Step 2: Reset Failed Nodes' Data

If old disks are being reused, wipe them:

```bash
# For Talos nodes, the reset command wipes the disk
talosctl reset --graceful=false --nodes <old-ip>
```

### Step 3: Regenerate and Apply

```bash
cd talos-mixed
just template configure
just bootstrap talos
```

### Step 4: Flux Should Re-sync Automatically

Flux watches the Git repo. Once nodes register and Cilium is healthy, Flux will reconcile all resources. Verify:

```bash
flux get sources git -A
kubectl get pods -A | grep -c Error
```

---

## Option B: Network Layout Change (New IPs/VIPs)

If migrating to a new subnet or changing VIPs:

### Step 1: Update `cluster.toml`

```toml
[network]
node_cidr = "192.168.2.0/24"  # new subnet
default_gateway = "192.168.2.1"

[kubernetes.api]
addr = "192.168.2.254"  # new Kube API VIP

[gateways]
internal = "192.168.2.250"
dns = "192.168.2.251"
external = "192.168.2.252"
```

### Step 2: Update `talos/topf.yaml`

Update all IPs, MACs, and disk serials for the new hardware.

### Step 3: Update DNS Records

- Update Cloudflare A records for services using external VIP
- Update DHCP reservations
- Update home DNS zone for split-DNS resolution

### Step 4: Bootstrap

```bash
just template configure
just bootstrap talos
```

---

## Option C: Complete Rebuild (Fresh Start)

### Step 1: Backup Everything

```bash
# Check VolSync backups exist
kubectl get volsyncbackups -A
kubectl get scheduledbackup -A

# Check Kopiur repositories
kubectl get clusterrepositories -A -n storage

# Verify recent backups
kubectl get podmonitor -A  # for monitoring
```

### Step 2: Document Current State

```bash
# List all apps
kubectl get helmreleases -A --no-headers | awk '{print $1, $2}'

# List all PVCs
kubectl get pvc -A --no-headers

# Export all custom resources (brief inventory)
for ns in $(kubectl get ns --no-headers | awk '{print $1}'); do
  for kind in $(kubectl api-resources --namespaced=true -o name | head -20); do
    count=$(kubectl get "$kind" -n "$ns" --no-headers 2>/dev/null | wc -l)
    [ "$count" -gt 0 ] && echo "$ns/$kind: $count"
  done
done
```

### Step 3: Destroy Existing Cluster

```bash
# On each node, wipe Talos
talosctl reset --nodes <ip> --graceful=false

# Or physically re-flash nodes from scratch
```

### Step 4: Re-bootstrap

Follow `bootstrap.md` from §2 onwards.

### Step 5: Restore Data

After the cluster is running:

```bash
# For VolSync restores (see disaster-recovery.md)
just volsync restore <app> <claim> <storage-class> <access-modes> <puid> <pgid>
```

---

## Post-Rebuild Verification

### 5.1 Cluster Health

```bash
# All nodes ready
kubectl get nodes -o wide

# Core services healthy
kubectl get pods -n kube-system | grep -c Running

# Flux synced
flux check

# Certificate validity
kubectl get certificates -A
```

### 5.2 GPU Health

```bash
# Intel iGPU
kubectl get nodes -l intel.feature.node.kubernetes.io/gpu=true
kubectl get pods -n ai -l app.kubernetes.io/name=ollama

# NVIDIA DRA
kubectl get resourceclaims -A
kubectl get inferenceservice -n ai
```

### 5.3 Storage Health

```bash
# Ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# PVC binding
kubectl get pvc -A | grep -v Bound

# Backup sources
kubectl get replicationsource -A
```

### 5.4 Service Connectivity

```bash
# Test internal access
curl -k https://<internal-service>.<domain>

# Test external access
curl -k https://<external-service>.<domain>
```

---

## Rollback Plan

If the rebuild fails partway through:

1. **If nodes are partially configured:** Re-flash with Talos ISO and restart from §2
2. **If Flux is partially synced:** Run `just bootstrap apps-helm` again — it's idempotent
3. **If secrets fail to decrypt:** Verify `$SOPS_AGE_KEY_FILE` matches the encrypted secrets
4. **If DNS is broken:** Temporarily configure static hosts entries while fixing Cloudflare records
