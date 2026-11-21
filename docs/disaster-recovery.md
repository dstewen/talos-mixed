# Disaster Recovery

Procedures for recovering from data loss, cluster corruption, or complete hardware failure.

---

## Recovery Hierarchy

This cluster uses a multi-tier backup strategy:

| Tier | Tool | Destination | Retention | Coverage |
|------|------|-------------|-----------|----------|
| **1 — Live Sync** | VolSync (Restic) | MinIO (local) | 72h continuous | PVCs, configmaps, secrets |
| **2 — Snapshot** | VolSync (Kopia) | NFS share | 720h (3yrs) | All PVCs |
| **3 — Off-site Copy** | VolSync (Kopia→MinIO) | Backblaze B2 | 720h (3yrs) | All PVCs |
| **4 — DB Backups** | CNPG Barman | MinIO + B2 | 2160h (90 days) | PostgreSQL clusters |
| **5 — Repository** | Git | Remote Git | Permanent | All manifests, configs, secrets |

> **Golden rule:** If you have Git + one successful backup copy, you can recover everything.

---

## RTO / RPO Targets

| Scenario | RPO (max data loss) | RTO (target recovery) |
|----------|---------------------|----------------------|
| Single pod failure | 0 (kubectl restart) | < 1 minute |
| Single node failure | 0 (replication) | < 5 minutes |
| Cluster corruption | 1 hour (VolSync last snapshot) | 30-60 minutes |
| Complete node loss (1-2 nodes) | 0 (replication) | 1-2 hours (replace node) |
| Complete cluster loss | 24 hours (last backup) | 2-4 hours (bootstrap + restore) |
| All nodes + storage loss | 24 hours | 4-8 hours |

---

## Procedure 1: Pod/Namespace Recovery

### 1.1 Restart a Failing Pod

```bash
kubectl rollout restart deploy/<app-name> -n <namespace>
kubectl rollout status deploy/<app-name> -n <namespace>
```

### 1.2 Recover a Deleted PVC

```bash
# Check if VolSync has a recent backup
kubectl get replicationsource -n <namespace> -o wide

# Restore using VolSync (manual restore)
kubectl create -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <pvc-name>-manual
  namespace: <namespace>
spec:
  trigger:
    manual: restore-once
  restic:
    repository: <app>-volsync-secret
    destinationPVC: <pvc-name>
    copyMethod: Direct
    storageClassName: ceph-block
    accessModes: ReadWriteOnce
    previous: "true"
EOF
```

---

## Procedure 2: Single-Node Loss

### 2.1 Identify and Drain

```bash
kubectl get nodes
kubectl cordon <failed-node>
kubectl drain <failed-node> --ignore-daemonsets --delete-emptydir-data --force
```

### 2.2 Replace the Node

- **Blade node:** Re-flash Talos, update `topf.yaml`, run `just template configure`, apply config
- **Control plane:** Replace with another MS node, update `topf.yaml`, bootstrap new CP
- **Spark/GPU node:** Re-flash Talos with DGX schematic, apply config

### 2.3 Verify Workloads Moved

```bash
kubectl get pods -A -o wide | grep <new-node>
```

---

## Procedure 3: Complete Cluster Recovery

### Step 1: Provision New/Replacement Hardware

See `bootstrap.md` for node setup. All nodes must be flashed with Talos and reachable on the network.

### Step 2: Restore Secrets

You need:
- `deploy.key` (or new deploy key + updated Git hosting)
- `$SOPS_AGE_KEY_FILE` (from backup)
- `cluster.toml` (from Git repo)

```bash
git clone <repo-url> talos-mixed
cd talos-mixed

# Restore from your key management system
cp /backup/sops-age.key ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
cp /backup/deploy.key .

# Initialize
just template init
```

### Step 3: Bootstrap the Cluster

```bash
just template configure
just bootstrap talos
```

### Step 4: Wait for Flux

```bash
# Flux should auto-sync. Verify:
flux get sources git -A
flux get kustomizations -A

# Check for errors:
flux logs -n flux-system --tail=50
```

### Step 5: Restore Data

#### 5a. Restore from VolSync (PVC data)

For each critical app:

```bash
# List available snapshots
kubectl exec -it <app-pod> -- restic snapshots --target /var/backup

# Or use the restore job template
just volsync restore <app> <pvc> ceph-block ReadWriteOnce 1000 1000

# For Kopia-based restores (NFS or B2 target):
kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app>-restore
  namespace: <ns>
spec:
  trigger:
    manual: restore-once
  kopia:
    repository: <app>-volsync-kopia-<target>
    destinationPVC: <pvc>
    copyMethod: Snapshot
    storageClassName: ceph-block
    accessModes: ReadWriteOnce
    retain:
      keepLast: 1
EOF
```

#### 5b. Restore PostgreSQL

```bash
# List available Barman backups
kubectl get backups -n database -o wide

# Create a new CNPG cluster from backup
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres18-restore
  namespace: database
spec:
  instances: 1
  bootstrap:
    recovery:
      source: <cluster-name>
      recoveryTarget:
        backupID: "20261115T080000"  # choose latest
  storage:
    storageClass: ceph-block
    size: 50Gi
EOF
```

#### 5c. Restore from Backblaze B2

```bash
# First restore to NFS, then to PVC
kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app>-b2-restore
  namespace: <ns>
spec:
  trigger:
    manual: restore-once
  kopia:
    repository: <app>-volsync-kopia-backblaze-b2
    destinationPVC: <pvc>
    copyMethod: Snapshot
    storageClassName: ceph-block
    accessModes: ReadWriteOnce
EOF
```

### Step 6: Verify

```bash
# All pods running
kubectl get pods -A | grep -c Running

# No errors
kubectl get pods -A | grep -c Error

# Services healthy
kubectl get svc -A
```

---

## Procedure 4: Secrets Recovery

### Age Key Lost

If you lost the SOPS age key, you cannot decrypt any `.sops.yaml` files.

1. Check for age key backups (1Password, encrypted home directory, etc.)
2. If none exist: you must **re-encrypt** all secrets with a new key
   - Decrypt each file using any available copy of the key
   - Generate new key: `age-keygen -o new-age.key`
   - Update `.sops.yaml` with new public key
   - Re-encrypt all files: `sops --in-place encrypt <file>`

### Git Deploy Key Lost

1. Generate new key: `ssh-keygen -t ed25519 -C "deploy-key" -f deploy.key`
2. Add public key to Git hosting (GitHub deploy key, GitLab deploy key, etc.)
3. Update `flux-webhook-token.txt` if also lost

---

## Procedure 5: DNS/Ingress Recovery

If external access is broken:

### 5a. Cloudflare Tunnel Down

```bash
# Check tunnel status
kubectl get pods -n network -l app.kubernetes.io/name=cloudflared

# Restart
kubectl rollout restart deploy/cloudflared -n network

# Check tunnel registration
kubectl logs -n network deploy/cloudflared --tail=20
```

### 5b. Internal DNS Broken

```bash
# Check k8s_gateway
kubectl get pods -n network -l app.kubernetes.io/name=k8s-gateway

# Verify DNS resolution from a pod
kubectl run -i --tty dns-test --image=busybox --rm --restart=Never -- nslookup kubernetes.default
```

---

## Recovery Checklist

Before starting any recovery:

- [ ] Verify backup sources are accessible (MinIO, NFS, B2)
- [ ] Verify `$SOPS_AGE_KEY_FILE` is available
- [ ] Verify `cluster.toml` is available (from Git repo or backup)
- [ ] Confirm replacement hardware is network-reachable
- [ ] Document current state for post-recovery comparison

After recovery completes:

- [ ] All nodes show `Ready=True`
- [ ] All pods show `Running` (or expected `Pending` for GPU on non-available nodes)
- [ ] Flux shows all sources `Ready` and kustomizations `Reconciled`
- [ ] Certificates are valid and not expiring within 30 days
- [ ] At least one VolSync ReplicationSource is running
- [ ] At least one CNPG backup has completed in the last 24h
- [ ] External services are accessible via tunnel
- [ ] Internal DNS resolution works

---

## Prevention — Keep Recovery Ready

### Weekly
- [ ] Verify at least one VolSync backup succeeded (check `kubectl get replicationdestination -A`)
- [ ] Verify CNPG backup completed (check `kubectl get backups -n database`)

### Monthly
- [ ] Perform a test restore of a non-critical PVC
- [ ] Verify `$SOPS_AGE_KEY_FILE` is backed up in a safe location
- [ ] Verify Git deploy key is current

### Quarterly
- [ ] Full DR drill: restore one app from B2 backup
- [ ] Verify age key rotation procedure (if practiced)
- [ ] Review and update RTO/RPO targets
