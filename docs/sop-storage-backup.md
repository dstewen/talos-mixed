# SOP — Storage & Backups

Procedures for managing storage infrastructure, backups, and data protection.

---

## Architecture Overview

### Storage Stack

| Component | Purpose | Backend |
|-----------|---------|---------|
| **Ceph (CSI)** | Block storage (RBD) | Ceph cluster on MS nodes |
| **Garage S3** | Object storage | Garage cluster |
| **MinIO** | Local backups, VolSync source | MinIO cluster |
| **NFS** | VolSync replication targets | NFS server (192.168.10.15) |
| **Backblaze B2** | Off-site VolSync targets | Cloud storage |
| **OpenEBS** | Local-path provisioner | Local disk |
| **Synology CSI** | iSCSI PVCs | Synology NAS |

### Backup Flow

```
PVC → VolSync (Kopia) → NFS → MinIO → VolSync (Kopia) → Backblaze B2
         ↑                    ↑                  ↑
      Snapshot method     Local target        Off-site target
```

For PostgreSQL (CNPG):
```
PG Cluster → Barman → MinIO → (manual) → Backblaze B2
```

---

## 1. PVC Creation

### 1.1 Standard PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <app-data>
  namespace: <namespace>
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block          # or cephfs, nfs, synology-iscsi
  resources:
    requests:
      storage: 50Gi
```

### 1.2 VolSync-Enabled PVC

Add the VolSync annotation for automatic backup:

```yaml
metadata:
  annotations:
    volsync.backube/trigger: "true"     # triggers backup creation
```

Then create the ReplicationSource:

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: <app>-kopia-minio-rsrc
  namespace: <namespace>
spec:
  sourcePVC: <app>
  trigger:
    schedule: "30 * * * *"              # every hour at :30
  kopia:
    repository: <app>-volsync-kopia-nfs
    copyMethod: Snapshot
    storageClassName: ceph-block
    retain:
      hourly: 24
      daily: 10
      weekly: 4
      monthly: 3
      yearly: 1
```

---

## 2. Volume Expansion

### 2.1 Expand a PVC

```bash
kubectl patch pvc <pvc-name> -n <namespace> \
  -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'

# Verify expansion
kubectl get pvc <pvc-name> -n <namespace>
```

**Notes:**
- Ceph RBD PVCs can be expanded in-place
- OpenEBS hostpath can be expanded if underlying disk has space
- NFS-backed PVCs typically cannot be expanded

---

## 3. Backup Operations

### 3.1 Trigger On-Demand VolSync Backup

```bash
# Trigger immediate backup for a ReplicationSource
kubectl patch replicationsource <app>-kopia-minio-rsrc -n <namespace> \
  --type merge -p '{"spec":{"trigger":{"manual":"backup-now"}}}'
```

### 3.2 List VolSync Snapshots

```bash
# Via the list job template
kubectl create -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: list-snapshots-$(date +%s)
  namespace: <namespace>
spec:
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: list
          image: docker.io/restic/restic:latest
          args: ["snapshots"]
          envFrom:
            - secretRef:
                name: <app>-volsync-secret
EOF
```

### 3.3 Trigger CNPG Backup

```bash
# Create an on-demand backup job
kubectl create -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: backup-now-$(date +%s)
  namespace: database
spec:
  template:
    spec:
      containers:
        - name: backup
          image: ghcr.io/cloudnative-pg/postgresql:18.6
          command: ["pg_basebackup"]
          args: ["--wal-method=stream"]
      restartPolicy: Never
EOF
```

### 3.4 Verify Backup Health

```bash
# Check all ReplicationSource statuses
kubectl get replicationsource -A -o wide

# Check ReplicationDestination sync status
kubectl get replicationdestination -A

# Check CNPG backups
kubectl get backups -n database
kubectl get scheduledbackup -A

# Check last backup age
kubectl get replicationsource <app>-kopia-minio-rsrc -n <namespace> -o jsonpath='{.status.lastSyncTime}'
```

---

## 4. Restore Operations

### 4.1 Restore PVC from VolSync (Direct)

```bash
kubectl create -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app>-restore
  namespace: <namespace>
spec:
  trigger:
    manual: restore-once
  restic:
    repository: <app>-volsync-secret
    destinationPVC: <app>
    copyMethod: Direct
    storageClassName: ceph-block
    accessModes: ReadWriteOnce
    previous: "true"
EOF
```

### 4.2 Restore PVC from VolSync (Kopia)

```bash
kubectl create -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app>-kopia-restore
  namespace: <namespace>
spec:
  trigger:
    manual: restore-once
  kopia:
    repository: <app>-volsync-kopia-nfs
    destinationPVC: <app>
    copyMethod: Snapshot
    storageClassName: ceph-block
    accessModes: ReadWriteOnce
    retain:
      keepLast: 1
EOF
```

### 4.3 Restore from Backblaze B2

```bash
# First restore to NFS (intermediate), then to PVC
kubectl create -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app>-b2-restore
  namespace: <namespace>
spec:
  trigger:
    manual: restore-once
  kopia:
    repository: <app>-volsync-kopia-backblaze-b2
    destinationPVC: <app>
    copyMethod: Snapshot
    storageClassName: ceph-block
    accessModes: ReadWriteOnce
EOF
```

### 4.4 Restore PostgreSQL from Backup

```bash
kubectl create -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres18-restore
  namespace: database
spec:
  instances: 1
  bootstrap:
    recovery:
      source: postgres18
      recoveryTarget:
        backupID: "20261115T080000"  # choose from kubectl get backups -n database
  storage:
    storageClass: ceph-block
    size: 50Gi
EOF
```

### 4.5 Monitor Restore Progress

```bash
# Check Restic copy jobs
kubectl get jobs -n <namespace> | grep volsync

# Check pod status during restore
kubectl get pods -n <namespace> | grep restore

# Check events
kubectl get events -n <namespace> --field-selector reason=VolumeSnapshotCreated
```

---

## 5. Storage Troubleshooting

### 5.1 PVC Stuck in Pending

```bash
# Check events
kubectl describe pvc <pvc-name> -n <namespace>

# Check available storage classes
kubectl get storageclass

# Check Ceph health
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

### 5.2 Ceph Cluster Degraded

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health detail
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph pg dump
```

### 5.3 MinIO Not Accessible

```bash
kubectl get pods -n storage -l app.kubernetes.io/name=minio
kubectl logs -n storage deploy/minio --tail=50
```

### 5.4 NFS Server Unreachable

```bash
# Check NFS server
curl http://192.168.10.15/api/2.0/storage/status.json

# Check NFS pod
kubectl get pods -n storage -l app.kubernetes.io/name=nfs
```

---

## 6. Volume Snapshots

### 6.1 List Snapshots

```bash
kubectl get volumesnapshot -A
```

### 6.2 Create a Snapshot

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: <app>-snapshot
  namespace: <namespace>
spec:
  volumeSnapshotClassName: csi-ceph-blockpool
  source:
    persistentVolumeClaimName: <app>
```

### 6.3 Restore from VolumeSnapshot

```bash
kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <app>-restored
  namespace: <namespace>
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block
  dataSource:
    name: <app>-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  resources:
    requests:
      storage: 50Gi
EOF
```
